@preconcurrency import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI

struct FriendsView: View {
    @Environment(PrivaEngine.self) private var engine
    let openFind: () -> Void
    let openChat: (String) -> Void

    var body: some View {
        List {
            let former = engine.incomingRequests.filter { $0.formerFriend == true }
            if !former.isEmpty {
                Section {
                    ForEach(former) { r in IncomingRequestRow(request: r) }
                    if former.count > 1 {
                        Button("Accept all \(former.count)", systemImage: "checkmark.circle.fill") { engine.acceptAllFormerFriends() }
                            .font(.headline)
                    }
                } header: { Text("Friends following you") } footer: {
                    Text("Friends from your previous username.")
                }
            }
            let renames = engine.friends.filter { $0.pendingRename != nil }
            if !renames.isEmpty {
                Section("Username changes") {
                    ForEach(renames) { c in RenameCard(contact: c) }
                }
            }
            let requests = engine.incomingRequests.filter { $0.formerFriend != true }
            if !requests.isEmpty {
                Section("Requests") {
                    ForEach(requests) { r in IncomingRequestRow(request: r) }
                }
            }
            if !engine.outgoingRequests.filter({ $0.rekey != true }).isEmpty {
                Section {
                    ForEach(engine.outgoingRequests.filter { $0.rekey != true }) { r in
                        HStack(spacing: 12) {
                            Avatar(name: r.username, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("@\(r.username)").font(.headline)
                                Text(r.expired ? "Expired" : "Pending").font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Button(r.expired ? "Remove" : "Cancel") { engine.withdrawRequest(r) }.buttonStyle(.glass).controlSize(.small)
                        }
                    }
                } header: { Text("Sent") } footer: {
                    Text("Delivered when they next open Priva.")
                }
            }
            Section(engine.friends.isEmpty ? "Friends" : engine.friends.count == 1 ? "1 friend" : "\(engine.friends.count) friends") {
                if engine.friends.isEmpty {
                    Button("Find someone by username", systemImage: "magnifyingglass", action: openFind)
                }
                ForEach(engine.friends) { c in
                    NavigationLink { ContactView(username: c.username, openChat: openChat) } label: {
                        HStack(spacing: 12) {
                            Avatar(name: c.username, size: 44, online: engine.presence[c.username] == .online)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(c.displayName).font(.headline)
                                    if c.verified { Image(systemName: "checkmark.shield.fill").font(.caption).foregroundStyle(Theme.mint).accessibilityLabel("Verified") }
                                }
                                Text(subtitle(c))
                                    .font(.caption).foregroundStyle(c.looksGone ? Theme.amber : Theme.textSecondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Friends")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Add friend", systemImage: "person.badge.plus", action: openFind) } }
        .animation(Theme.snappy, value: engine.incomingRequests.count)
    }

    /// No nickname or shared name yet → the title already is the username, so show status instead.
    private func subtitle(_ c: Contact) -> String {
        if c.looksGone { return "@\(c.username) · uninstalled Priva" }
        if c.displayName != c.username { return "@\(c.username)" }
        if engine.presence[c.username] == .online { return "online" }
        return c.verified ? "verified" : "not verified yet"
    }
}

struct IncomingRequestRow: View {
    @Environment(PrivaEngine.self) private var engine
    let request: IncomingRequest
    @State private var busy = false
    @State private var confirmKeyChange = false
    @State private var confirmBlock = false
    @State private var reporting = false

    /// A failed accept says so and can be tried again (the button used to stay greyed out for good).
    private func accept() {
        busy = true
        do { try engine.accept(request) } catch {
            busy = false
            engine.toast = .init(title: "Couldn't accept", body: "Try again in a moment.", contact: nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Avatar(name: request.username, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.name ?? "@\(request.username)").font(.headline)
                    if request.name != nil { Text("@\(request.username)").font(.caption.monospaced()).foregroundStyle(Theme.textSecondary) }
                    if request.formerFriend == true {
                        Label("Friend of your previous username", systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(Theme.mint)
                    } else {
                        Text(request.receivedAt.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            if request.keyChange == true {
                Label("Not their usual key: someone may be listening in. Decline unless they confirm in person.",
                      systemImage: "exclamationmark.shield.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.rose)
            }
            if let taken = request.moveConflict {
                Label("Claims to be @\(request.renamedFrom ?? "?"), but that account already moved to @\(taken). Decline unless @\(taken) confirms in person.",
                      systemImage: "exclamationmark.shield.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.rose)
            }
            if let note = request.note, !note.isEmpty {
                Text("“\(note)”").font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            if request.keyChange == true, let b = try? KeyBundle.parse(request.bundleRaw) {
                Text("Key fingerprint " + b.fingerprint.prefix(6).hex.uppercased().chunked(4))
                    .font(.caption.monospaced()).foregroundStyle(Theme.textTertiary)
            }
            HStack {
                Button("Decline", role: .destructive) { engine.decline(request) }.buttonStyle(.glass)
                Menu {
                    Button("Block", systemImage: "hand.raised.fill", role: .destructive) { confirmBlock = true }
                    Button("Report", systemImage: "exclamationmark.bubble.fill", role: .destructive) { reporting = true }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("More for @\(request.username)")
                Spacer()
                Button {
                    if request.keyChange == true || request.moveConflict != nil { confirmKeyChange = true; return }
                    accept()
                } label: { Label(request.keyChange == true ? "Replace keys" : "Accept", systemImage: "checkmark") }
                .buttonStyle(.glassProminent).tint(request.keyChange == true ? Theme.rose : Theme.violet).disabled(busy)
            }
        }
        .padding(.vertical, 6)
        .confirmationDialog("Replace @\(request.username)'s security keys?", isPresented: $confirmKeyChange, titleVisibility: .visible) {
            Button("Replace keys", role: .destructive) { accept() }
        } message: {
            Text("Only if they told you in person they set up Priva again. Then compare security codes.")
        }
        .sensoryFeedback(.success, trigger: busy)
        .blockConfirmation(request.username, isPresented: $confirmBlock)
        .sheet(isPresented: $reporting) {
            let note = request.note.map { [Message(id: request.id, contact: request.username, outgoing: false, kind: .text, text: "Friend request note: \($0)",
                                                    attachment: nil, sentAt: request.receivedAt, status: .received)] } ?? []
            ReportSheet(username: request.username, place: "Friend request", candidates: note).environment(engine)
        }
    }
}

extension String {
    func chunked(_ n: Int) -> String {
        stride(from: 0, to: count, by: n).map { i -> String in
            let s = index(startIndex, offsetBy: i), e = index(s, offsetBy: min(n, count - i))
            return String(self[s..<e])
        }.joined(separator: " ")
    }
}

// MARK: - Find

struct FindUserView: View {
    @Environment(PrivaEngine.self) private var engine
    let openChat: (String) -> Void
    /// A username from a scanned code or `priva://add/…` link, searched as soon as Find opens.
    var link: String? = nil
    var linkUsed: () -> Void = {}
    @State private var query = ""
    @State private var scanning = false
    @State private var result: PrivaEngine.FoundUser?
    @State private var state: SearchState = .idle
    @State private var note = ""
    @State private var sent = false
    @State private var sendError: String?
    @State private var warming: Task<Void, Never>?

    enum SearchState: Equatable { case idle, searching, found, notFound, uninstalled, isSelf, error }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                switch state {
                case .idle:
                    EmptyStateView(icon: "at", title: "Find by exact username",
                                   message: "Enter your friend's full username, like cedar_lunar_pilot_5821.")
                case .searching:
                    ProgressView().padding(40)
                case .notFound:
                    EmptyStateView(icon: "person.fill.questionmark", title: "No one named @\(Username.normalize(query))",
                                   message: "Check the spelling.")
                case .uninstalled:
                    EmptyStateView(icon: "moon.zzz", title: "@\(Username.normalize(query)) isn't active",
                                   message: "This username is no longer on Priva.")
                case .isSelf:
                    EmptyStateView(icon: "person.crop.circle", title: "That's you", message: "Share @\(engine.me) with friends so they can add you.")
                case .error:
                    EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't search", message: "Check your connection and try again.")
                case .found:
                    if let b = result { resultCard(b) }
                }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Find")
        .searchable(text: $query, prompt: "Exact username")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { _, v in
            if v.isEmpty { state = .idle; result = nil }
            warm(v)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Scan code", systemImage: "qrcode.viewfinder") { scanning = true }
            }
        }
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                scanning = false
                if let name = Username.fromAddLink(code) { open(name) } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    engine.toast = .init(title: "Not a Priva code", body: "Scan the code on a friend's profile.", contact: nil)
                }
            }
            .ignoresSafeArea()
        }
        .task(id: link) { if let link { linkUsed(); open(link) } }
    }

    private func open(_ name: String) {
        query = name
        Task { await search() }
    }

    /// The directory only knows a memory-hard hash of each username (≈ 0.5 s on a phone; it's what stops anyone
    /// listing the directory). Work it out during a pause in typing, so Search waits only for the network.
    private func warm(_ text: String) {
        warming?.cancel()
        if !text.isEmpty { PrivaAPI.shared.warmUp() }
        let name = Username.normalize(text)
        guard Username.isValid(name), name != engine.me else { return }
        warming = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await Self.derive(name)
        }
    }

    @concurrent nonisolated private static func derive(_ name: String) async { _ = UsernameKey.derive(name) }

    private func search() async {
        state = .searching
        sent = false
        do {
            result = try await engine.findUser(query)
            state = .found
        } catch PrivaEngine.FriendError.notFound { state = .notFound }
        catch PrivaEngine.FriendError.uninstalled { state = .uninstalled }
        catch PrivaEngine.FriendError.isSelf { state = .isSelf }
        catch { state = .error }
    }

    @ViewBuilder private func resultCard(_ u: PrivaEngine.FoundUser) -> some View {
        let b = u.bundle
        let isFriend = engine.contact(u.username) != nil
        let pending = engine.outgoingRequests.contains { $0.username == u.username }
        VStack(spacing: 16) {
            Avatar(name: u.username, size: 88)
            Text("@\(u.username)").font(.title3.monospaced().weight(.bold)).minimumScaleFactor(0.6).lineLimit(1)
            VStack(spacing: 4) {
                Text("Public key fingerprint").font(.caption).foregroundStyle(Theme.textSecondary)
                Text(b.fingerprint.prefix(12).hex.uppercased().chunked(4)).font(.caption.monospaced()).foregroundStyle(Theme.textPrimary)
            }
            SecureChip(text: "Keys signed by @\(u.username)", compact: true)
            if isFriend {
                PrimaryButton(title: "Message", systemImage: "bubble.left.fill") { openChat(u.username) }
            } else if pending || sent {
                Label("Request sent", systemImage: "paperplane.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.mint)
            } else {
                TextField("Add a note (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(14)
                    .background(Theme.surface2, in: .rect(cornerRadius: 14))
                    .onChange(of: note) { _, v in if v.count > 140 { note = String(v.prefix(140)) } }
                PrimaryButton(title: "Send friend request", systemImage: "person.badge.plus") {
                    do {
                        sendError = nil
                        try engine.sendFriendRequest(to: u, note: note.isEmpty ? nil : note)
                        withAnimation(Theme.snappy) { sent = true }
                    } catch PrivaEngine.FriendError.alreadyFriends {
                        sendError = "You're already friends."
                    } catch PrivaEngine.FriendError.alreadyPending {
                        sendError = "A request to @\(u.username) is already waiting."
                    } catch {
                        sendError = "Couldn't send the request. Try again."
                    }
                }
                if let sendError {
                    Text(sendError).font(.footnote.weight(.semibold)).foregroundStyle(Theme.rose).multilineTextAlignment(.center)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: .rect(cornerRadius: 28))
        .sensoryFeedback(.success, trigger: sent)
    }
}

// MARK: - Contact

struct ContactView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var size
    let username: String
    var openChat: ((String) -> Void)?
    @State private var confirmRemove = false
    @State private var confirmBlock = false
    @State private var reporting = false
    @State private var nickname = ""

    var body: some View {
        let c = engine.contact(username)
        List {
            Section {
                VStack(spacing: 12) {
                    Avatar(name: username, size: 96, online: engine.presence[username] == .online)
                    Text(c?.displayName ?? username).font(.title2.weight(.bold))
                    Text("@\(username)").foregroundStyle(Theme.textSecondary)
                    // Side by side normally; stacked at accessibility text sizes, where three fixed tiles cut their labels.
                    let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 14))
                    layout {
                        action("Message", "bubble.left.fill") { if let openChat { openChat(username) } else { dismiss() } }
                        action("Voice", "phone.fill") { call(video: false) }
                        action("Video", "video.fill") { call(video: true) }
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            if let c, c.pendingRename != nil {
                Section { RenameCard(contact: c) }
            } else if c?.looksGone == true {
                Section {
                    Label("@\(username) left Priva. If they come back, their new username shows up here.", systemImage: "moon.zzz")
                        .font(.subheadline).foregroundStyle(Theme.amber)
                }
            }
            Section("Security") {
                NavigationLink { SafetyNumberView(username: username) } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Security code")
                            Text(c?.verified == true ? "Verified in person" : "Not verified").font(.caption).foregroundStyle(c?.verified == true ? Theme.mint : Theme.amber)
                        }
                    } icon: { Image(systemName: c?.verified == true ? "checkmark.shield.fill" : "shield.lefthalf.filled").foregroundStyle(c?.verified == true ? Theme.mint : Theme.amber) }
                }
                Picker(selection: Binding(get: { c?.disappearAfter ?? 0 }, set: { engine.setDisappearing(username, $0 == 0 ? nil : $0) })) {
                    Text("Off").tag(TimeInterval(0))
                    Text("5 minutes").tag(TimeInterval(300))
                    Text("1 hour").tag(TimeInterval(3600))
                    Text("1 day").tag(TimeInterval(86_400))
                    Text("1 week").tag(TimeInterval(604_800))
                } label: { Label("Disappearing messages", systemImage: "timer") }
                #if DEBUG
                LabeledContent {
                    Text("epoch \(c?.pair.epoch ?? 0)").font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                } label: { Label("Pair key ratchet", systemImage: "arrow.triangle.2.circlepath") }
                #endif
            }
            Section("Nickname") {
                TextField("Only visible to you", text: $nickname)
                    .onSubmit { saveNickname() }
            }
            Section {
                Button("Remove friend", systemImage: "person.fill.xmark", role: .destructive) { confirmRemove = true }
                Button("Block @\(username)", systemImage: "hand.raised.fill", role: .destructive) { confirmBlock = true }
                Button("Report @\(username)", systemImage: "exclamationmark.bubble.fill", role: .destructive) { reporting = true }
            } footer: {
                Text("Removing or blocking deletes this chat. Blocking also stops their calls and invites.")
            }
        }
        .navigationTitle(c?.displayName ?? username)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nickname = c?.nickname ?? "" }
        .onDisappear { saveNickname() }                   // Back without pressing Return keeps it too
        .confirmationDialog("Remove @\(username)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { engine.removeFriend(username); dismiss() }
        }
        .blockConfirmation(username, isPresented: $confirmBlock) { dismiss() }
        .sheet(isPresented: $reporting) {
            ReportSheet(username: username, place: "1:1 chat",
                        candidates: engine.loadThread(username).filter { !$0.outgoing && $0.kind != .system && $0.kind != .call }) { dismiss() }
                .environment(engine)
        }
    }

    private func saveNickname() {
        guard engine.contact(username) != nil, nickname != (engine.contact(username)?.nickname ?? "") else { return }
        engine.setNickname(username, nickname)
    }

    /// Opened as a sheet from the chat (no `openChat`): it closes first, or the call screen can't appear over it.
    private func call(video: Bool) {
        guard openChat == nil else { engine.calls.start(peer: username, video: video); return }
        dismiss()
        Task { try? await Task.sleep(for: .milliseconds(400)); engine.calls.start(peer: username, video: video) }
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(minWidth: 84, maxWidth: size.isAccessibilitySize ? .infinity : nil, minHeight: 64)
        }
        .buttonStyle(.glass)
    }
}

struct SafetyNumberView: View {
    @Environment(PrivaEngine.self) private var engine
    let username: String
    @State private var scanning = false
    @State private var scanResult: Bool?
    /// 2,048 SHA-512 rounds + a post-quantum signature check: worked out once, not on every redraw.
    @State private var digits: [String]?
    @State private var theirs: KeyBundle?
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        let c = engine.contact(username)
        ScrollView {
            VStack(spacing: 22) {
                Text("Compare with @\(username) in person. If they match, your chat is private.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                if let digits {
                    // Each five-digit group stays on one line, or it can't be compared: fewer columns at large sizes.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: size.isAccessibilitySize ? 2 : size >= .xxLarge ? 3 : 4), spacing: 12) {
                        ForEach(Array(digits.enumerated()), id: \.offset) { _, g in
                            Text(g).font(.system(.title3, design: .monospaced).weight(.semibold)).foregroundStyle(Theme.textPrimary)
                                .lineLimit(1).minimumScaleFactor(0.5)
                        }
                    }
                    .padding(20)
                    .background(Theme.surface, in: .rect(cornerRadius: 22))
                    .accessibilityLabel("Security code: " + digits.joined(separator: " "))
                }
                VStack(spacing: 10) {
                    Text("Your code").font(.headline)
                    QRCodeView(text: SafetyNumber.qrPayload(username: engine.me, bundle: engine.myBundle)).frame(width: 200, height: 200)
                    Text("Let @\(username) scan this").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .padding(20)
                .background(Theme.surface, in: .rect(cornerRadius: 22))
                if let scanResult {
                    Label(scanResult ? "Codes match: verified" : "Codes do NOT match", systemImage: scanResult ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .font(.headline).foregroundStyle(scanResult ? Theme.mint : Theme.rose)
                }
                SecondaryButton(title: "Scan their code", systemImage: "qrcode.viewfinder") { scanning = true }
                PrimaryButton(title: c?.verified == true ? "Mark as unverified" : "Mark as verified", systemImage: "checkmark.shield") {
                    engine.setVerified(username, !(c?.verified ?? false))
                }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Security code")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: c?.bundleRaw) {
            let me = engine.me, mine = engine.myBundle, name = username, raw = c?.bundleRaw
            let result = await Task.detached(priority: .userInitiated) { () -> (KeyBundle, [String])? in
                guard let raw, let b = try? KeyBundle.parse(raw) else { return nil }
                return (b, SafetyNumber.digits(me: me, mine, them: name, b))
            }.value
            theirs = result?.0
            digits = result?.1
        }
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                scanning = false
                guard let b = theirs else { return }
                let ok = SafetyNumber.matches(qr: code, username: username, bundle: b)
                scanResult = ok
                if ok { engine.setVerified(username, true) }
                UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
            }
            .ignoresSafeArea()
        }
    }
}

struct QRCodeView: View {
    let text: String
    var body: some View {
        if let img = Self.make(text) {
            Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                .padding(10).background(.white, in: .rect(cornerRadius: 14))
                .accessibilityLabel("QR code")
        }
    }

    static func make(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Camera QR scanner (AVFoundation metadata output). Shows a message where no camera exists.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerVC { let vc = ScannerVC(); vc.onCode = onCode; return vc }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                let l = UILabel()
                l.text = "Camera unavailable"
                l.textColor = .white
                l.frame = view.bounds
                l.textAlignment = .center
                l.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(l)
                return
            }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            if session.canAddOutput(out) {
                session.addOutput(out)
                out.setMetadataObjectsDelegate(self, queue: .main)
                out.metadataObjectTypes = [.qr]
            }
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
            MainActor.assumeIsolated {
                guard !done, let code else { return }
                done = true
                onCode?(code)
            }
        }
    }
}


/// "@old is now @new": the friend's choice to follow a username change (IDENTITY_DESIGN §7).
/// A friend's account restored on another iPhone, waiting (audit SEC-04): followed when their old iPhone confirms,
/// or at `followAt`; the user can follow now, or refuse.
struct MoveCard: View {
    @Environment(PrivaEngine.self) private var engine
    let contact: Contact
    let move: PrivaEngine.PendingMove

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Avatar(name: move.request.username, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(move.request.name ?? contact.displayName) restored their account").font(.headline)
                    Text("@\(contact.username) → @\(move.request.username)").font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                        .lineLimit(2).minimumScaleFactor(0.7)
                }
            }
            Label("Following \(move.followAt.formatted(date: .omitted, time: .shortened)) \(Calendar.current.isDateInToday(move.followAt) ? "today" : "tomorrow"), "
                  + "or as soon as their old iPhone confirms. Not sure? Ask them.", systemImage: "clock.badge.checkmark")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            HStack {
                Button("Not them") { engine.refuseMove(of: contact.username) }.buttonStyle(.glass)
                Spacer()
                Button { engine.followMoveNow(of: contact.username) } label: { Label("Follow now", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.glassProminent).tint(Theme.violet)
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("move.card")
    }
}

struct RenameCard: View {
    @Environment(PrivaEngine.self) private var engine
    let contact: Contact
    @State private var sent = false

    var body: some View {
        if let r = contact.pendingRename {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Avatar(name: r.newUsername, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(r.name ?? contact.displayName) has a new username").font(.headline)
                        Text("@\(contact.username) → @\(r.newUsername)").font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                            .lineLimit(2).minimumScaleFactor(0.7)
                    }
                }
                Label("Verified with their previous keys", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(Theme.mint)
                if sent {
                    Label("Update sent", systemImage: "paperplane.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.mint)
                } else {
                    HStack {
                        Button("Dismiss") { engine.dismissRename(of: contact.username) }.buttonStyle(.glass)
                        Spacer()
                        Button {
                            if (try? engine.acceptRename(of: contact.username)) != nil { withAnimation(Theme.snappy) { sent = true } }
                        } label: { Label("Update", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.glassProminent).tint(Theme.violet)
                    }
                }
            }
            .padding(.vertical, 6)
            .onAppear { sent = engine.outgoingRequests.contains { $0.migratesContact == contact.username } }
            .sensoryFeedback(.success, trigger: sent)
        }
    }
}
