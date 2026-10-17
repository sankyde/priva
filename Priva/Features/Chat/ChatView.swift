import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let username: String
    @State private var draft = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var pickOriginal = false
    @State private var showPicker = false
    @State private var showFiles = false
    @State private var viewing: Message?
    @State private var infoFor: Message?
    @State private var showContact = false
    @State private var preparing = 0
    @State private var atBottom = true
    /// Set once the first message is loaded; until then the top of the chat loads another page each time it shows.
    @State private var reachedStart = false
    @FocusState private var composerFocused: Bool

    private enum Item: Identifiable {
        case day(Date)
        case message(Message, first: Bool, last: Bool)
        var id: String {
            switch self {
            case .day(let d): return "d\(Int(d.timeIntervalSince1970))"
            case .message(let m, _, _): return m.id
            }
        }
    }

    private var items: [Item] {
        let msgs = engine.threads[username] ?? []
        var out: [Item] = []
        out.reserveCapacity(msgs.count + 8)
        let cal = Calendar.current
        for (i, m) in msgs.enumerated() {
            if i == 0 || !cal.isDate(msgs[i - 1].sentAt, inSameDayAs: m.sentAt) { out.append(.day(cal.startOfDay(for: m.sentAt))) }
            let prev = i > 0 ? msgs[i - 1] : nil, next = i + 1 < msgs.count ? msgs[i + 1] : nil
            func same(_ o: Message?) -> Bool {
                guard let o else { return false }
                return o.outgoing == m.outgoing && o.kind != .system && o.kind != .call && abs(o.sentAt.timeIntervalSince(m.sentAt)) < 180
                    && cal.isDate(o.sentAt, inSameDayAs: m.sentAt)
            }
            out.append(.message(m, first: !same(prev), last: !same(next)))
        }
        return out
    }

    var body: some View {
        let contact = engine.contact(username)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ChatHeaderSection(username: username, contact: contact) { showContact = true }
                        .onAppear { if !reachedStart { reachedStart = !engine.loadOlder(username) } }
                    ForEach(items) { item in
                        switch item {
                        case .day(let d):
                            Text(Format.day.string(from: d)).font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                                .padding(.vertical, 10)
                        case .message(let m, let first, let last):
                            MessageRow(message: m, groupFirst: first, groupLast: last,
                                       onOpen: { viewing = m }, onInfo: { infoFor = m })
                                .id(m.id)
                                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    if engine.typing.contains(username) {
                        TypingBubble().frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4).id("typing")
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                    }
                    Color.clear.frame(height: 6).id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 12)
                .animation(Theme.snappy, value: engine.threads[username]?.count)
                .animation(Theme.snappy, value: engine.typing.contains(username))
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background.ignoresSafeArea())
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button { withAnimation(Theme.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                        Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .padding(16)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Scroll to latest")
                }
            }
            .onChange(of: engine.threads[username]?.last?.id) { _, _ in
                if atBottom || engine.threads[username]?.last?.outgoing == true {
                    withAnimation(Theme.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                ComposerBar(text: $draft, focused: $composerFocused, preparing: preparing > 0,
                            onSend: send, onPhotos: { original in pickOriginal = original; showPicker = true },
                            onFiles: { showFiles = true })
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showContact = true } label: { ChatTitle(username: username) }.buttonStyle(.plain)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Voice call", systemImage: "phone.fill") { engine.calls.start(peer: username, video: false) }
                Button("Video call", systemImage: "video.fill") { engine.calls.start(peer: username, video: true) }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { sendFiles(urls) }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            let chosen = items
            pickerItems = []
            sendPicked(chosen, original: pickOriginal)
        }
        .onChange(of: draft) { old, new in
            if old.isEmpty != new.isEmpty { engine.setTyping(!new.isEmpty, to: username) }
        }
        .onAppear { engine.openChat = username; _ = engine.loadThread(username) }
        // Removed or blocked (from the profile sheet): this chat no longer exists.
        .onChange(of: engine.contact(username).map { $0.groupOnly != true } ?? false) { _, friend in if !friend { dismiss() } }
        .onDisappear {
            if engine.openChat == username { engine.openChat = nil }
            if !draft.isEmpty { engine.setTyping(false, to: username) }
        }
        .fullScreenCover(item: $viewing) { m in MediaViewer(message: m).environment(engine) }
        .sheet(item: $infoFor) { m in MessageInfoSheet(message: m).presentationDetents([.medium]) }
        .sheet(isPresented: $showContact) { NavigationStack { ContactView(username: username) }.environment(engine) }
    }

    private func send() {
        let text = draft
        draft = ""
        engine.setTyping(false, to: username)
        if !engine.send(text: text, to: username) { draft = text }
    }

    private func sendPicked(_ items: [PhotosPickerItem], original: Bool) {
        preparing += items.count
        for item in items {
            Task {
                defer { preparing -= 1 }
                do {
                    let prepared: MediaPrep.Prepared
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return }
                        prepared = try await MediaPrep.video(from: movie.url, optimize: !original)
                        try? FileManager.default.removeItem(at: movie.url)
                    } else {
                        guard let data = try await item.loadTransferable(type: Data.self) else { return }
                        prepared = try await Task.detached { try MediaPrep.image(from: data, maxPixel: original ? 0 : 3072) }.value
                    }
                    await engine.send(media: prepared, to: username)
                } catch {
                    engine.toast = .init(title: "Couldn't send", body: "That item couldn't be prepared.", contact: nil)
                }
            }
        }
    }

    private func sendFiles(_ urls: [URL]) {
        for url in urls {
            preparing += 1
            Task {
                defer { preparing -= 1 }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                guard let prepared = try? MediaPrep.file(at: url) else {
                    engine.toast = .init(title: "Couldn't send \(url.lastPathComponent)", body: "Priva couldn't read that file.", contact: nil)
                    return
                }
                await engine.send(media: prepared, to: username)
            }
        }
    }
}

struct ChatTitle: View {
    @Environment(PrivaEngine.self) private var engine
    let username: String

    var body: some View {
        let c = engine.contact(username)
        let presence = engine.presence[username] ?? .offline
        HStack(spacing: 10) {
            Avatar(name: username, size: 34, online: presence == .online)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(c?.displayName ?? username).font(.headline).lineLimit(1)
                    if c?.verified == true { Image(systemName: "checkmark.shield.fill").font(.caption).foregroundStyle(Theme.mint) }
                }
                Text(status(presence, c)).font(.caption).foregroundStyle(presence == .online ? Theme.mint : Theme.textSecondary)
                    .contentTransition(.opacity)
            }
        }
        .animation(Theme.snappy, value: presence)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows contact details and security code")
    }

    private func status(_ p: PrivaEngine.Presence, _ c: Contact?) -> String {
        if engine.typing.contains(username) { return "typing…" }
        switch p {
        case .online: return "online"
        case .connecting: return "connecting…"
        case .offline:
            if let seen = c?.lastSeen { return "seen \(seen.formatted(.relative(presentation: .named)))" }
            return "offline"
        }
    }
}

struct ChatHeaderSection: View {
    @Environment(PrivaEngine.self) private var engine
    let username: String
    let contact: Contact?
    let onVerify: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            EncryptionHeader(username: username, verified: contact?.verified ?? false, keyChanged: contact?.keyChangedAt != nil, verify: onVerify)
                .padding(.bottom, 4)
            if let c = contact, let move = engine.pendingMoves[c.username] {
                MoveCard(contact: c, move: move).padding(14).background(Theme.surface, in: .rect(cornerRadius: 20))
            } else if let c = contact, c.pendingRename != nil {
                RenameCard(contact: c).padding(14).background(Theme.surface, in: .rect(cornerRadius: 20))
            } else if contact?.looksGone == true {
                Label("@\(username) left Priva", systemImage: "moon.zzz")
                    .font(.caption).foregroundStyle(Theme.amber)
            }
        }
        .padding(.bottom, 8)
    }
}

struct EncryptionHeader: View {
    let username: String
    let verified: Bool
    let keyChanged: Bool
    let verify: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            SecureChip()
            if keyChanged {
                Button(action: verify) { Label("Security code changed: verify", systemImage: "exclamationmark.triangle.fill") }
                    .font(.caption.weight(.semibold)).tint(Theme.amber).buttonStyle(.glass)
            } else if !verified {
                Button("Verify security code", systemImage: "qrcode.viewfinder", action: verify)
                    .font(.caption.weight(.semibold)).buttonStyle(.glass)
            }
        }
        .padding(.top, 16)
    }
}

// MARK: - Bubbles

struct MessageRow: View {
    @Environment(PrivaEngine.self) private var engine
    let message: Message
    let groupFirst: Bool
    let groupLast: Bool
    let onOpen: () -> Void
    let onInfo: () -> Void
    /// Group threads: who wrote an incoming message, and an admin/author "delete for everyone".
    var senderName: String? = nil
    var onDeleteForEveryone: (() -> Void)? = nil

    var body: some View {
        switch message.kind {
        case .system:
            Text(message.text ?? "").font(.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                .padding(.horizontal, 24).padding(.vertical, 8).frame(maxWidth: .infinity)
        case .call:
            Label(message.text ?? "Call", systemImage: message.text?.contains("Video") == true || message.text?.contains("video") == true ? "video.fill" : "phone.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(message.text?.hasPrefix("Missed") == true ? Theme.rose : Theme.textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Theme.surface2, in: .capsule)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        default:
            HStack(alignment: .bottom, spacing: 0) {
                if message.outgoing { Spacer(minLength: 56) }
                if !message.outgoing, senderName != nil {
                    Group {
                        if groupLast { Avatar(name: message.sender ?? "?", size: 28) } else { Color.clear.frame(width: 28, height: 1) }
                    }
                    .padding(.trailing, 6)
                    .padding(.bottom, groupLast ? 18 : 0)
                }
                VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 3) {
                    if let senderName, groupFirst, !message.outgoing {
                        Text(senderName).font(.caption.weight(.semibold)).foregroundStyle(Theme.tint).padding(.leading, 12)
                    }
                    bubble
                    if groupLast { meta }
                }
                if !message.outgoing { Spacer(minLength: 56) }
            }
            .padding(.top, groupFirst ? 8 : 1)
        }
    }

    @ViewBuilder private var bubble: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: !message.outgoing && !groupFirst ? 6 : Theme.bubbleRadius,
            bottomLeadingRadius: !message.outgoing && !groupLast ? 6 : Theme.bubbleRadius,
            bottomTrailingRadius: message.outgoing && !groupLast ? 6 : Theme.bubbleRadius,
            topTrailingRadius: message.outgoing && !groupFirst ? 6 : Theme.bubbleRadius)
        Group {
            if let a = message.attachment {
                AttachmentBubble(attachment: a, outgoing: message.outgoing,
                                 live: message.outgoing ? engine.uploadProgress[a.fileID] : engine.downloadProgress[a.fileID], onOpen: onOpen,
                                 onDownload: { engine.download(message) })
                    .clipShape(shape)
            } else {
                Text(message.text ?? "")
                    .font(.body)
                    .foregroundStyle(message.outgoing ? .white : Theme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(message.outgoing ? AnyShapeStyle(Theme.auroraSoft) : AnyShapeStyle(Theme.incomingBubble), in: shape)
                    // No system text selection: its Copy goes to Universal Clipboard and stays there. The menu's Copy
                    // is this iPhone only and clears itself (audit SEC-22).
            }
        }
        .contextMenu {
            if let t = message.text {
                Button("Copy", systemImage: "doc.on.doc") { SecurePasteboard.copy(t) }
            }
            if let a = message.attachment, MediaSaver.canSave(a, outgoing: message.outgoing) {
                Button("Save to Photos", systemImage: "square.and.arrow.down") { engine.saveToPhotos(a) }
            }
            if message.outgoing && (message.status == .queued || message.status == .failed) {
                Button("Retry now", systemImage: "arrow.clockwise") { engine.retry(message) }
            }
            Button("Info", systemImage: "info.circle", action: onInfo)
            if let onDeleteForEveryone {
                Button("Delete for everyone", systemImage: "trash.slash", role: .destructive, action: onDeleteForEveryone)
            }
            Button("Delete for me", systemImage: "trash", role: .destructive) { engine.delete(message) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.outgoing ? "You" : senderName ?? engine.contact(message.contact)?.displayName ?? message.contact): \(message.text ?? message.attachment?.name ?? "")")
    }

    private var meta: some View {
        HStack(spacing: 4) {
            if message.expiresAt != nil { Image(systemName: "timer").font(.caption2) }
            Text(Format.time.string(from: message.sentAt)).font(.caption2)
            if message.outgoing {
                Button(action: onInfo) { StatusGlyph(status: message.status, onGradient: false).frame(minWidth: 30, minHeight: 30).contentShape(.rect) }
                    .buttonStyle(.plain)
                if message.status == .queued { Text("Waiting to send").font(.caption2) }
            }
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 6)
    }
}

struct AttachmentBubble: View {
    let attachment: Attachment
    let outgoing: Bool
    /// Progress of a transfer under way (upload or download), when there is one.
    let live: Double?
    let onOpen: () -> Void
    var onDownload: () -> Void = {}

    var body: some View {
        let progress = outgoing ? (attachment.isComplete ? 1 : (live ?? 0)) : (attachment.isComplete ? 1 : max(live ?? 0, attachment.progress))
        if attachment.expired == true || (attachment.unavailable == true && !attachment.isComplete) {
            expired
        } else if attachment.held == true, !outgoing, !attachment.isComplete {
            held
        } else if attachment.notBackedUp == true {
            notBackedUp
        } else {
            content(progress)
        }
    }

    /// Restored from a text-only backup: the thumbnail (when there was one) and a short note.
    private var notBackedUp: some View {
        HStack(spacing: 10) {
            if let t = attachment.thumbnail, let img = SafeImage.thumbnail(t) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 8))
            } else {
                Image(systemName: attachment.kind == .file ? "doc" : "photo").font(.title3)
                    .foregroundStyle(outgoing ? .white.opacity(0.8) : Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.kind == .video ? "Video" : attachment.kind == .image ? "Photo" : attachment.displayName)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("Not in backup").font(.caption).opacity(0.75)
            }
        }
        .padding(10)
        .accessibilityElement(children: .combine)
    }

    /// Too big to fetch by itself: the thumbnail (if any) and a Download button with the size.
    private var held: some View {
        Button(action: onDownload) {
            HStack(spacing: 10) {
                if let t = attachment.thumbnail, let img = SafeImage.thumbnail(t) {
                    Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 8))
                } else {
                    Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Theme.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.kind == .video ? "Video" : attachment.kind == .image ? "Photo" : attachment.displayName)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("Download · \(Format.bytes(attachment.size))").font(.caption).foregroundStyle(Theme.tint)
                }
                .foregroundStyle(Theme.textPrimary)
            }
            .padding(12)
            .frame(minWidth: 200, alignment: .leading)
            .background(Theme.incomingBubble)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Download \(attachment.displayName), \(Format.bytes(attachment.size))")
        .accessibilityIdentifier("attachment.download")
    }

    /// Group media older than 90 days: the file, key and thumbnail are gone; only this note remains.
    private var expired: some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.kind == .file ? "doc.badge.clock" : "photo.badge.exclamationmark")
                .font(.title3).foregroundStyle(outgoing ? .white.opacity(0.8) : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.kind == .video ? "Video removed" : attachment.kind == .image ? "Photo removed" : "File removed")
                    .font(.subheadline.weight(.semibold))
                Text(attachment.unavailable == true ? "The sender no longer has it" : "Group media is kept for 90 days")
                    .font(.caption).opacity(0.75)
            }
            .foregroundStyle(outgoing ? .white : Theme.textPrimary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(outgoing ? AnyShapeStyle(Theme.auroraSoft.opacity(0.6)) : AnyShapeStyle(Theme.incomingBubble))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func content(_ progress: Double) -> some View {
        Button(action: onOpen) {
            switch attachment.kind {
            case .image, .video:
                ZStack {
                    if let img = MediaVault.shared.thumbnail(for: attachment) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Theme.surface2)
                    }
                    if attachment.kind == .video, progress >= 1 {
                        Image(systemName: "play.fill").font(.title2).foregroundStyle(.white)
                            .frame(width: 54, height: 54).glassEffect(.clear, in: .circle)
                    }
                    if progress < 1 { TransferRing(progress: progress, outgoing: outgoing) }
                }
                .frame(width: 240, height: min(320, max(150, 240 / max(0.5, attachment.aspect))))
                .overlay(alignment: .bottomTrailing) {
                    if let d = attachment.duration {
                        Text(PrivaEngine.clock(d)).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.45), in: .capsule).padding(8)
                    }
                }
                .clipped()
            case .file:
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(outgoing ? .white.opacity(0.2) : Theme.surface2).frame(width: 44, height: 50)
                        if progress < 1 { TransferRing(progress: progress, outgoing: outgoing).scaleEffect(0.6) }
                        else { Image(systemName: "doc.fill").foregroundStyle(outgoing ? .white : Theme.violet) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attachment.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(progress < 1 ? "\(Int(progress * 100))% · \(Format.bytes(attachment.size))" : Format.bytes(attachment.size))
                            .font(.caption.monospacedDigit())
                            .opacity(0.8)
                    }
                    .foregroundStyle(outgoing ? .white : Theme.textPrimary)
                }
                .padding(12)
                .frame(width: 250, alignment: .leading)
                .background(outgoing ? AnyShapeStyle(Theme.auroraSoft) : AnyShapeStyle(Theme.incomingBubble))
            }
        }
        .buttonStyle(.plain)
        .disabled(progress < 1 && !outgoing)
        .accessibilityIdentifier("attachment.open")
    }
}

struct TransferRing: View {
    let progress: Double
    let outgoing: Bool
    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.35))
            Circle().stroke(.white.opacity(0.25), lineWidth: 4)
            Circle().trim(from: 0, to: max(0.03, progress)).stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.15), value: progress)
            Image(systemName: outgoing ? "arrow.up" : "arrow.down").font(.caption.weight(.bold)).foregroundStyle(.white)
        }
        .frame(width: 50, height: 50)
        .accessibilityLabel("\(outgoing ? "Sending" : "Receiving") \(Int(progress * 100)) percent")
    }
}

struct TypingBubble: View {
    @State private var phase = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(Theme.textSecondary).frame(width: 7, height: 7)
                    .scaleEffect(1 + 0.35 * sin(phase + Double(i) * 0.9))
                    .opacity(0.5 + 0.5 * sin(phase + Double(i) * 0.9))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.incomingBubble, in: .capsule)
        .onAppear {
            guard !reduceMotion else { phase = .pi / 2; return }      // three still dots
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = .pi * 2 }
        }
        .accessibilityLabel("Typing")
    }
}

// MARK: - Composer

struct ComposerBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let preparing: Bool
    let onSend: () -> Void
    let onPhotos: (_ original: Bool) -> Void
    let onFiles: () -> Void
    @Namespace private var ns

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("Photos & videos", systemImage: "photo.on.rectangle") { onPhotos(false) }
                    Button("Photos at full quality", systemImage: "photo.badge.checkmark") { onPhotos(true) }
                    Button("File", systemImage: "doc") { onFiles() }
                } label: {
                    Group {
                        if preparing { ProgressView() } else { Image(systemName: "plus").font(.title3.weight(.semibold)) }
                    }
                    .frame(width: 46, height: 46)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Attach")

                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused(focused)
                    .accessibilityIdentifier("composer")
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(minHeight: 46)
                    .glassEffect(.regular, in: .rect(cornerRadius: 23))
                    .glassEffectID("field", in: ns)

                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // The glass button style, not .plain + an interactive glassEffect: that pair let the glass take
                    // the touch, and the send action never ran for a synthetic tap (found by SocialJourneys).
                    Button(action: onSend) {
                        Image(systemName: "arrow.up").font(.headline.weight(.bold)).foregroundStyle(.white).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(Theme.violet)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("composer.send")
                    .sensoryFeedback(.impact(weight: .medium), trigger: text.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .animation(Theme.bouncy, value: text.isEmpty)
    }
}

// MARK: - Info & viewer

struct MessageInfoSheet: View {
    let message: Message
    var body: some View {
        NavigationStack {
            List {
                if message.outgoing {
                    Section {
                        LabeledContent("Status", value: statusText)
                        if message.status == .queued {
                            Text("Sends when they're next online.").font(.footnote).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                Section {
                    LabeledContent("Sent", value: message.sentAt.formatted(date: .abbreviated, time: .standard))
                    if let r = message.receivedAt, !message.outgoing { LabeledContent("Received", value: r.formatted(date: .abbreviated, time: .standard)) }
                    if let e = message.expiresAt { LabeledContent("Disappears", value: e.formatted(date: .abbreviated, time: .shortened)) }
                    if let a = message.attachment {
                        LabeledContent("File", value: a.displayName)
                        LabeledContent("Size", value: Format.bytes(a.size))
                    }
                }
            }
            .navigationTitle("Message info")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var statusText: String {
        switch message.status {
        case .queued: return "Waiting to send"
        case .sending: return "Sending"
        case .delivered: return "Delivered"
        case .read: return "Read"
        case .failed: return "Failed"
        case .received: return "Received"
        }
    }
}

struct MediaViewer: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let message: Message
    @State private var image: UIImage?
    @State private var unreadable = false
    @State private var player: AVPlayer?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var exportURL: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let a = message.attachment {
                switch a.kind {
                case .image:
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                            .accessibilityLabel(message.outgoing ? "Your photo" : "Photo")
                            .scaleEffect(scale).offset(offset)
                            .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }.onEnded { _ in withAnimation(Theme.snappy) { if scale < 1.1 { scale = 1; offset = .zero } } })
                            .simultaneousGesture(DragGesture().onChanged { v in if scale > 1 { offset = v.translation } else { offset = CGSize(width: 0, height: v.translation.height) } }
                                .onEnded { v in if scale <= 1 && abs(v.translation.height) > 120 { dismiss() } else if scale <= 1 { withAnimation(Theme.snappy) { offset = .zero } } })
                            .onTapGesture(count: 2) { withAnimation(Theme.snappy) { scale = scale > 1 ? 1 : 2.5; offset = .zero } }
                    } else if unreadable {
                        Label("This photo can't be shown", systemImage: "photo.badge.exclamationmark")
                            .font(.headline).foregroundStyle(.white)
                    } else { ProgressView().tint(.white) }
                case .video:
                    if let player { VideoPlayer(player: player).ignoresSafeArea() } else { ProgressView().tint(.white) }
                case .file:
                    VStack(spacing: 16) {
                        Image(systemName: "doc.fill").font(.system(size: 64)).foregroundStyle(Theme.aurora)
                        Text(a.displayName).font(.headline).foregroundStyle(.white)
                        Text(Format.bytes(a.size)).foregroundStyle(.white.opacity(0.7))
                        Button("Share a copy…", systemImage: "square.and.arrow.up") { export(a) }.buttonStyle(.glassProminent)
                        Text("The copy isn't encrypted.").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44) }
                .accessibilityLabel("Close").accessibilityIdentifier("viewer.close")
                .buttonStyle(.plain).foregroundStyle(.white).glassEffect(.regular.interactive(), in: .circle).padding()
                .accessibilityLabel("Close")
        }
        .overlay(alignment: .topTrailing) {
            if let a = message.attachment, MediaSaver.canSave(a, outgoing: message.outgoing) {
                Button { engine.saveToPhotos(a) } label: { Image(systemName: "square.and.arrow.down").font(.headline).frame(width: 44, height: 44) }
                    .buttonStyle(.plain).foregroundStyle(.white).glassEffect(.regular.interactive(), in: .circle).padding()
                    .accessibilityLabel("Save to Photos")
            }
        }
        .overlay(alignment: .bottom) {
            if let t = engine.toast { ToastView(title: t.title, message: t.body).padding(.bottom, 24).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(Theme.snappy, value: engine.toast)
        .task {
            guard let a = message.attachment else { return }
            switch a.kind {
            case .image:
                image = await MediaVault.shared.image(for: a, store: engine.store)
                unreadable = image == nil
            case .video:
                if let item = MediaVault.shared.playerItem(for: a, store: engine.store) {
                    let p = AVPlayer(playerItem: item)
                    player = p
                    p.play()
                }
            case .file: break
            }
        }
        .onDisappear {
            player?.pause()
            if let f = message.attachment?.fileID { MediaVault.shared.releasePlayer(f) }
            if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        }
        .sheet(item: Binding(get: { exportURL.map(ExportItem.init) }, set: { if $0 == nil { exportURL = nil } })) { item in
            ShareSheet(url: item.url)
        }
        .statusBarHidden()
        .hiddenWhileCaptured()
    }

    private func export(_ a: Attachment) {
        Task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(MediaPrep.sanitize(a.name))
            let src = engine.store.mediaURL(a.fileID), key = a.key
            let ok = await Task.detached { () -> Bool in
                guard let r = try? FileCipher.Reader(url: src, key: .init(data: key)) else { return false }
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
                guard let h = try? FileHandle(forWritingTo: url) else { return false }
                defer { try? h.close() }
                for i in 0..<r.header.chunkCount { guard let c = try? r.plainChunk(i) else { return false }; try? h.write(contentsOf: c) }
                return true
            }.value
            if ok { exportURL = url }
        }
    }
}

struct ExportItem: Identifiable { let url: URL; var id: String { url.path } }

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Copies stay on this device (no Universal Clipboard) and expire after two minutes.
enum SecurePasteboard {
    static func copy(_ s: String) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: s]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
    }
}
