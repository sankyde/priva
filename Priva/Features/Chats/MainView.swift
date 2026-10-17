import SwiftUI

struct MainView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(AppModel.self) private var model
    @State private var tab = TabID.chats
    @State private var chatPath: [String] = []
    @State private var movedShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var size

    enum TabID: Hashable { case chats, friends, calls, settings, find }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: TabID.chats) {
                NavigationStack(path: $chatPath) {
                    ChatsListView(openFind: { tab = .find }, openThread: { chatPath = [$0] })
                        .navigationDestination(for: String.self) { ThreadDestination(key: $0) }
                }
            }
            .badge(engine.summaries.reduce(0) { $0 + $1.unread } + engine.groupActivity.values.reduce(0) { $0 + $1.unread } + engine.groups.invites.count)
            Tab("Friends", systemImage: "person.2.fill", value: TabID.friends) {
                NavigationStack { FriendsView(openFind: { tab = .find }, openChat: openChat) }
            }
            .badge(engine.incomingRequests.count)
            Tab("Calls", systemImage: "phone.fill", value: TabID.calls) {
                NavigationStack { CallsListView() }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: TabID.settings) {
                NavigationStack { SettingsView() }
            }
            Tab("Find", systemImage: "magnifyingglass", value: TabID.find, role: .search) {
                NavigationStack { FindUserView(openChat: openChat, link: model.pendingAdd) { model.pendingAdd = nil } }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .top) { banners }
        .sheet(isPresented: $movedShown) { AccountMovedView().environment(engine).environment(model) }
        .onAppear {
            if engine.accountMoved != nil { movedShown = true }
            if model.pendingAdd != nil { tab = .find }
        }
        .onChange(of: model.pendingAdd) { _, name in if name != nil { tab = .find } }
        .onChange(of: engine.accountMoved) { _, n in if n != nil { movedShown = true } }
        .fullScreenCover(isPresented: Binding(get: { engine.calls.call != nil || engine.groupCalls.call != nil },
                                              set: { if !$0 { engine.calls.call = nil; engine.groupCalls.call = nil } })) {
            Group {
                if engine.calls.call != nil { CallView() } else { GroupCallView() }
            }
            .environment(engine)
            .environment(\.colorScheme, .dark)         // the call screens are always dark: so are their controls
        }
        .onChange(of: engine.toast) { _, t in
            guard let t else { return }
            // VoiceOver users hear it, and get longer to.
            AccessibilityNotification.Announcement("\(t.title). \(t.body)").post()
            let shown: Double = UIAccessibility.isVoiceOverRunning ? 8 : 3.2
            Task { try? await Task.sleep(for: .seconds(shown)); if engine.toast == t { withAnimation(Theme.snappy) { engine.toast = nil } } }
        }
    }

    private var connectingText: String {
        guard NetworkPrivacy.current.mode == .tor else { return "Connecting…" }
        if case .starting(let p) = TorService.shared.state { return "Connecting through Tor · \(p)%" }
        return "Connecting through Tor…"
    }

    private func openChat(_ username: String) {
        tab = .chats
        chatPath = [username]
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 8) {
            if let moved = engine.accountMoved {
                Button { movedShown = true } label: {
                    Label(moved.answer == nil ? "Your account is being moved to @\(moved.newUsername): was this you?"
                          : moved.answer == true ? "Your account moved to @\(moved.newUsername) on another iPhone"
                          : "You told friends the move to @\(moved.newUsername) wasn't you",
                          systemImage: moved.answer == false ? "exclamationmark.shield.fill" : "iphone.and.arrow.forward")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.amber)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
            } else if engine.realtimeStatus != .connected {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    // At accessibility sizes the words would cover the toolbar's buttons: the spinner says enough.
                    if !size.isAccessibilitySize {
                        Text(connectingText).font(.caption.weight(.semibold)).contentTransition(.numericText())
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(connectingText)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            if let t = engine.toast {
                ToastView(title: t.title, message: t.body)
                    .onTapGesture {
                        if let c = t.contact { openChat(c) }
                        engine.toast = nil
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .id(t.id)
            }
        }
        .animation(Theme.snappy, value: engine.realtimeStatus)
        .animation(Theme.snappy, value: engine.toast)
        .padding(.top, 4)
    }
}

// MARK: - Chats list

/// Routes a thread key: "g:<id>" is a group, anything else a friend's username.
struct ThreadDestination: View {
    let key: String
    var body: some View {
        if key.hasPrefix("g:") { GroupChatView(gid: String(key.dropFirst(2))) } else { ChatView(username: key) }
    }
}

struct ChatsListView: View {
    @Environment(PrivaEngine.self) private var engine
    let openFind: () -> Void
    let openThread: (String) -> Void
    @State private var query = ""
    @State private var found: [Message] = []
    @State private var searching: Task<Void, Never>?
    @State private var composing = false
    @State private var creatingGroup = false
    /// When the "backups are off" note was last dismissed (it comes back after 30 days). Only a time is stored.
    @AppStorage("nudge.backup.dismissed") private var backupNudgeDismissed = 0.0

    private var showsBackupNudge: Bool {
        !engine.backup.isOn && !engine.summaries.isEmpty && q.isEmpty
            && Date().timeIntervalSince1970 - backupNudgeDismissed > 30 * 86_400
    }

    private enum Row: Identifiable {
        case direct(PrivaEngine.Summary)
        case group(PrivaGroup)
        var id: String {
            switch self {
            case .direct(let s): return s.contact.username
            case .group(let g): return g.threadKey
            }
        }
    }

    private var q: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func named(_ s: String) -> Bool { s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }

    /// Conversations by name or @username; groups also by any member's name.
    private var rows: [Row] {
        var out: [(Date, Row)] = engine.summaries
            .filter { q.isEmpty || named($0.contact.displayName) || named($0.contact.username) }
            .map { ($0.last?.sentAt ?? $0.contact.addedAt, .direct($0)) }
        for g in engine.groups.groups.values
        where q.isEmpty || named(g.name) || g.members.contains(where: { named($0.username) || named(engine.name(of: $0.username, in: g)) }) {
            out.append((engine.groupActivity[g.id]?.last?.sentAt ?? g.created, .group(g)))
        }
        return out.sorted { $0.0 > $1.0 }.map(\.1)
    }

    private func search(_ text: String) {
        searching?.cancel()
        found = []
        let store = engine.store
        searching = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let hits = await Self.messages(matching: text, in: store)
            if !Task.isCancelled { found = hits }
        }
    }

    @concurrent nonisolated private static func messages(matching text: String, in store: Store) async -> [Message] {
        store.searchMessages(text) { Task.isCancelled }
    }

    /// In a group, who wrote it (nothing for your own posts or 1:1 chats).
    private func sender(of m: Message) -> String? {
        guard m.contact.hasPrefix("g:"), !m.outgoing, let s = m.sender else { return nil }
        return engine.name(of: s, in: engine.groups.groups[String(m.contact.dropFirst(2))])
    }

    private func title(of m: Message) -> String {
        if m.contact.hasPrefix("g:"), let g = engine.groups.groups[String(m.contact.dropFirst(2))] {
            return g.name
        }
        return engine.contact(m.contact)?.displayName ?? m.contact
    }

    var body: some View {
        Group {
            if engine.summaries.isEmpty && engine.groups.groups.isEmpty && engine.groups.invites.isEmpty {
                EmptyStateView(icon: "bubble.left.and.text.bubble.right", title: "No conversations yet",
                               message: "Add a friend by their username to start chatting.",
                               actionTitle: "Find a friend", action: openFind)
            } else {
                List {
                    if engine.phraseUnsaved, q.isEmpty {
                        NavigationLink { RecoveryPhraseRevealView() } label: {
                            WarningNote(text: "Your recovery phrase changed. Tap to see the new one.", systemImage: "list.number")
                        }
                        .accessibilityIdentifier("nudge.phrase")
                        .listRowBackground(Theme.amber.opacity(0.10))
                        .listRowSeparator(.hidden)
                    }
                    if showsBackupNudge {
                        HStack(spacing: 10) {
                            NavigationLink { BackupSettingsView() } label: {
                                WarningNote(text: "Backups are off. Tap to turn them on.", systemImage: "lock.icloud.fill")
                            }
                            .accessibilityIdentifier("nudge.backup")
                            Button("Not now", systemImage: "xmark") { withAnimation(Theme.snappy) { backupNudgeDismissed = Date().timeIntervalSince1970 } }
                                .labelStyle(.iconOnly).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                                .frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("nudge.backup.dismiss")
                        }
                        .listRowBackground(Theme.amber.opacity(0.10))
                        .listRowSeparator(.hidden)
                    }
                    if !engine.groups.invites.isEmpty {
                        Section {
                            ForEach(engine.groups.invites) { inv in
                                GroupInviteCard(invite: inv).listRowBackground(Color.clear).listRowSeparator(.hidden)
                            }
                        }
                    }
                    if !q.isEmpty && rows.isEmpty && found.isEmpty {
                        ContentUnavailableView.search(text: q).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .direct(let s):
                            NavigationLink(value: s.contact.username) {
                                ChatRow(summary: s, presence: engine.presence[s.contact.username] ?? .offline,
                                        typing: engine.typing.contains(s.contact.username))
                            }
                            .accessibilityIdentifier("chat.\(s.contact.username)")
                            .listRowBackground(Theme.background)
                            .listRowSeparatorTint(Theme.hairline)
                            .swipeActions(edge: .trailing) {
                                Button("Call", systemImage: "phone.fill") { engine.calls.start(peer: s.contact.username, video: false) }.tint(Theme.mint)
                            }
                        case .group(let g):
                            NavigationLink(value: g.threadKey) { GroupRow(group: g) }
                                .accessibilityIdentifier("group.\(g.name)")
                                .listRowBackground(Theme.background)
                                .listRowSeparatorTint(Theme.hairline)
                                .swipeActions(edge: .trailing) {
                                    if !g.ended {
                                        Button("Call", systemImage: "phone.fill") { engine.groupCalls.start(gid: g.id, video: false) }.tint(Theme.mint)
                                    }
                                }
                        }
                    }
                    if !found.isEmpty {
                        Section("Messages") {
                            ForEach(found) { m in
                                Button { openThread(m.contact) } label: {
                                    MessageHit(title: title(of: m), sender: sender(of: m), message: m, query: q)
                                }
                                .accessibilityIdentifier("search.message")
                                .listRowBackground(Theme.background)
                                .listRowSeparatorTint(Theme.hairline)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(Theme.snappy, value: engine.groups.invites.count)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Chats")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search chats and messages")
        .onChange(of: query) { _, v in search(v) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New chat", systemImage: "bubble.left") { composing = true }
                    Button("New group", systemImage: "person.3") { creatingGroup = true }
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $composing) { ComposeSheet(onPick: openThread) }
        .sheet(isPresented: $creatingGroup) { NewGroupSheet(onCreated: { openThread("g:\($0)") }).environment(engine) }
    }
}

/// A message found by search: where it is, a snippet around the match, when.
struct MessageHit: View {
    let title: String
    let sender: String?
    let message: Message
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                Text(Format.relative(message.sentAt)).font(.caption).foregroundStyle(Theme.textTertiary)
            }
            Text(Self.snippet(sender.map { "\($0): " } ?? "", message.text ?? message.attachment?.name ?? "", query))
                .font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(2)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// Starts a little before the match so it's always visible, with the match in bold.
    static func snippet(_ prefix: String, _ text: String, _ q: String) -> AttributedString {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let r = flat.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return AttributedString(prefix + flat) }
        let start = flat.index(r.lowerBound, offsetBy: -24, limitedBy: flat.startIndex) ?? flat.startIndex
        var out = AttributedString(prefix + (start > flat.startIndex ? "…" : "") + String(flat[start..<r.lowerBound]))
        var hit = AttributedString(String(flat[r]))
        hit.font = .subheadline.weight(.bold)
        hit.foregroundColor = Theme.textPrimary
        out += hit
        out += AttributedString(String(flat[r.upperBound...]))
        return out
    }
}

struct ChatRow: View {
    let summary: PrivaEngine.Summary
    let presence: PrivaEngine.Presence
    let typing: Bool
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        // At accessibility sizes the time goes under the name, so the name isn't squeezed to a few letters.
        let stacked = size.isAccessibilitySize
        HStack(spacing: 14) {
            Avatar(name: summary.contact.username, size: 54, online: presence == .online)
                .accessibilityHidden(true)                       // the row reads the name once
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(summary.contact.displayName).font(.headline).foregroundStyle(Theme.textPrimary).lineLimit(stacked ? 2 : 1)
                    if summary.contact.verified {
                        Image(systemName: "checkmark.shield.fill").font(.caption).foregroundStyle(Theme.mint).accessibilityLabel("Verified")
                    }
                    Spacer()
                    if !stacked, let d = summary.last?.sentAt { time(d) }
                }
                if stacked, let d = summary.last?.sentAt { time(d) }
                HStack(spacing: 6) {
                    if typing {
                        Text("typing…").font(.subheadline.italic()).foregroundStyle(Theme.violet)
                    } else if let m = summary.last {
                        if m.outgoing, m.kind != .system, m.kind != .call { StatusGlyph(status: m.status, onGradient: false) }
                        Text(preview(m)).font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(2)
                            .accessibilityLabel(spokenPreview(m))
                    }
                    Spacer(minLength: 0)
                    if summary.unread > 0 {
                        Text("\(summary.unread)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                            .background(Theme.aurora, in: .capsule)
                            .accessibilityLabel("\(summary.unread) unread")
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func time(_ d: Date) -> some View {
        Text(Format.relative(d)).font(.caption).foregroundStyle(summary.unread > 0 ? Theme.tint : Theme.textTertiary)
    }

    /// The preview without its emoji, for VoiceOver ("Photo", not "camera Photo").
    private func spokenPreview(_ m: Message) -> String {
        guard m.kind == .media else { return m.text ?? "" }
        switch m.attachment?.kind {
        case .image: return "Photo"
        case .video: return "Video"
        default: return "File, \(m.attachment?.name ?? "")"
        }
    }

    private func preview(_ m: Message) -> String {
        switch m.kind {
        case .media:
            switch m.attachment?.kind {
            case .image: return "📷 Photo"
            case .video: return "🎬 Video"
            default: return "📎 \(m.attachment?.name ?? "File")"
            }
        default: return m.text ?? ""
        }
    }
}

struct ComposeSheet: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    /// Opens the chat in Chats (not inside this sheet, where swiping down would close the conversation).
    let onPick: (String) -> Void
    var body: some View {
        NavigationStack {
            List(engine.friends) { c in
                Button {
                    dismiss()
                    onPick(c.username)
                } label: {
                    HStack(spacing: 12) {
                        Avatar(name: c.username, size: 40).accessibilityHidden(true)
                        Text(c.displayName).font(.headline).foregroundStyle(Theme.textPrimary)
                    }
                }
                .accessibilityIdentifier("compose.\(c.username)")
            }
            .overlay { if engine.friends.isEmpty { EmptyStateView(icon: "person.2", title: "No friends yet", message: "Use Find to add someone by username.") } }
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } } }
        }
    }
}

/// Old iPhone: this account was restored (or signed back in) on another iPhone. Only someone holding this account's
/// keys can send that notice, so it was either you, or someone with your Backup Key and password.
struct AccountMovedView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmErase = false

    var body: some View {
        switch engine.accountMoved?.answer {
        case .none: askView
        case .some(false): warnedView
        case .some(true): movedView
        }
    }

    /// "Was this you?" (audit SEC-04): the answer reaches every friend over the connection they already trust.
    private var askView: some View {
        let n = engine.accountMoved
        return OnboardingScaffold(title: "Was this you?", subtitle: "Your account is being restored on another iPhone as @\(n?.newUsername ?? "?").") {
            VStack(alignment: .leading, spacing: 14) {
                Label("You (a new iPhone, a restored backup)? Say so: your friends follow you there at once.",
                      systemImage: "checkmark.circle.fill").font(.subheadline)
                Label("Not you? Someone has your recovery phrase, or a backup and its password. Say so: your friends won't follow, and they'll be warned.",
                      systemImage: "exclamationmark.shield.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.rose)
                Label("No answer: friends follow in 12 hours.", systemImage: "clock").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .background(Theme.surface, in: .rect(cornerRadius: 18, style: .continuous))
        } footer: {
            VStack(spacing: 10) {
                PrimaryButton(title: "It was me") { engine.answerMove(mine: true) }
                    .accessibilityIdentifier("move.mine")
                Button("It wasn't me", role: .destructive) { engine.answerMove(mine: false) }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.rose).frame(minHeight: 44)
                    .accessibilityIdentifier("move.notMine")
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .hiddenWhileCaptured()
    }

    private var warnedView: some View {
        let n = engine.accountMoved
        return OnboardingScaffold(title: "Your friends were warned", subtitle: "They won't follow @\(n?.newUsername ?? "?"), and they know it wasn't you.") {
            VStack(alignment: .leading, spacing: 14) {
                Label("Your account carries on here.", systemImage: "checkmark.shield.fill").font(.subheadline)
                Label("Someone has your recovery phrase, or a backup and its password. Keep both private, and tell your friends in person.",
                      systemImage: "exclamationmark.shield.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.rose)
            }
            .padding(16)
            .background(Theme.surface, in: .rect(cornerRadius: 18, style: .continuous))
        } footer: {
            PrimaryButton(title: "OK") { dismiss() }
        }
        .background(Theme.background.ignoresSafeArea())
        .hiddenWhileCaptured()
    }

    private var movedView: some View {
        let n = engine.accountMoved
        return OnboardingScaffold(title: "Your account moved", subtitle: "It was restored on another iPhone\(n.map { " on \($0.at.formatted(date: .abbreviated, time: .shortened))" } ?? "").") {
            VStack(alignment: .leading, spacing: 14) {
                Label("It's now @\(n?.newUsername ?? "?") on the other iPhone. This one keeps a read-only copy.",
                      systemImage: "iphone.and.arrow.forward").font(.subheadline)
            }
            .padding(16)
            .background(Theme.surface, in: .rect(cornerRadius: 18, style: .continuous))
        } footer: {
            VStack(spacing: 10) {
                // The safe choice is the main button; erasing is red and asks again.
                PrimaryButton(title: "Keep the read-only copy") { dismiss() }
                Button("Erase Priva from this iPhone", role: .destructive) { confirmErase = true }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.rose).frame(minHeight: 44)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .hiddenWhileCaptured()
        .confirmationDialog("Erase everything on this iPhone?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { dismiss(); model.wipe() }
        } message: { Text("Your account continues on the other iPhone. Backups in iCloud are kept.") }
    }
}
