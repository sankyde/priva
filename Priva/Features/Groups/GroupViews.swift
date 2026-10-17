import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Building blocks

struct GroupAvatar: View {
    let name: String
    var size: CGFloat = 54

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(Theme.aurora)
            .overlay {
                ZStack(alignment: .bottomTrailing) {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: size * 0.2, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(size * 0.1)
                }
            }
            .frame(width: size, height: size)
            .accessibilityLabel("Group \(name)")
    }
}

struct RoleBadge: View {
    let role: PrivaGroup.Role
    var body: some View {
        switch role {
        case .host: badge("Host", icon: "crown.fill", color: Theme.violet)
        case .admin: badge("Admin", icon: "shield.lefthalf.filled", color: Theme.cyan)
        case .member: EmptyView()
        }
    }

    private func badge(_ t: String, icon: String, color: Color) -> some View {
        // HStack, not Label: inside a List a Label gets icon-column spacing.
        HStack(spacing: 4) { Image(systemName: icon); Text(t) }
            .font(.caption2.weight(.bold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3).background(color.opacity(0.14), in: .capsule)
            .accessibilityElement(children: .combine)
    }
}

extension PrivaGroup {
    var memberCountText: String { members.count == 1 ? "1 member" : "\(members.count) members" }
}

// MARK: - Chats list

struct GroupRow: View {
    @Environment(PrivaEngine.self) private var engine
    let group: PrivaGroup

    var body: some View {
        let act = engine.groupActivity[group.id]
        HStack(spacing: 14) {
            GroupAvatar(name: group.name, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(group.name).font(.headline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if group.host == engine.me {
                        Image(systemName: "crown.fill").font(.caption).foregroundStyle(Theme.violet).accessibilityLabel("You host this group")
                    }
                    Spacer()
                    if let d = act?.last?.sentAt {
                        Text(Format.relative(d)).font(.caption).foregroundStyle((act?.unread ?? 0) > 0 ? Theme.violet : Theme.textTertiary)
                    }
                }
                HStack(spacing: 6) {
                    Text(preview(act?.last)).font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    Spacer(minLength: 0)
                    if let n = act?.unread, n > 0 {
                        Text("\(n)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                            .background(Theme.aurora, in: .capsule)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func preview(_ m: Message?) -> String {
        guard let m else { return group.ended ? "Group ended" : group.memberCountText }
        let body: String
        switch m.kind {
        case .media:
            switch m.attachment?.kind {
            case .image: body = "📷 Photo"
            case .video: body = "🎬 Video"
            default: body = "📎 \(m.attachment?.name ?? "File")"
            }
        default: body = m.text ?? ""
        }
        guard m.kind == .text || m.kind == .media else { return body }
        let who = m.outgoing ? "You" : engine.name(of: m.sender ?? "", in: group)
        return "\(who): \(body)"
    }
}

struct GroupInviteCard: View {
    @Environment(PrivaEngine.self) private var engine
    let invite: GroupHub.Invite

    var body: some View {
        let g = invite.snapshot.group
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                GroupAvatar(name: g.name, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.name).font(.headline)
                    let n = invite.snapshot.memberCount ?? g.members.count
                    Text("\(engine.name(of: invite.from)) invited you · \(n == 1 ? "1 member" : "\(n) members")").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Label("Hosted on \(engine.name(of: invite.from))'s iPhone, which can read the group.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            HStack {
                Button("Decline") { withAnimation(Theme.snappy) { engine.groups.respond(to: invite, accept: false) } }.buttonStyle(.glass)
                Spacer()
                Button("Join group") { withAnimation(Theme.snappy) { engine.groups.respond(to: invite, accept: true) } }
                    .buttonStyle(.glassProminent).tint(Theme.violet)
            }
        }
        .padding(16)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
    }
}

// MARK: - New group

struct NewGroupSheet: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void
    @State private var name = ""
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Group name", text: $name).font(.headline)
                } footer: {
                    Text("Your iPhone hosts the group and relays its messages and calls.")
                }
                Section("Invite friends · \(selected.count)") {
                    if engine.friends.isEmpty {
                        Text("Groups are made from friends. Add one in Find first.").foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(engine.friends) { c in
                        Button {
                            if selected.contains(c.username) { selected.remove(c.username) } else { selected.insert(c.username) }
                        } label: {
                            HStack(spacing: 12) {
                                Avatar(name: c.username, size: 38)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.displayName).font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                                    if c.displayName != c.username {
                                        Text("@\(c.username)").font(.caption).foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: selected.contains(c.username) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(selected.contains(c.username) ? Theme.violet : Theme.textTertiary)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .accessibilityAddTraits(selected.contains(c.username) ? .isSelected : [])
                        .accessibilityIdentifier("pick.\(c.username)")
                    }
                }
            }
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let g = try? engine.groups.create(name: name, members: Array(selected)) else {
                            engine.toast = .init(title: "Couldn't create the group", body: "Try again in a moment.", contact: nil)
                            return
                        }
                        dismiss()
                        onCreated(g.id)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
                }
            }
            .sensoryFeedback(.selection, trigger: selected)
        }
    }
}

// MARK: - Group chat

struct GroupChatView: View {
    @Environment(PrivaEngine.self) private var engine
    let gid: String
    @State private var draft = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var pickOriginal = false
    @State private var showPicker = false
    @State private var showFiles = false
    @State private var viewing: Message?
    @State private var infoFor: Message?
    @State private var showInfo = false
    @State private var preparing = 0
    @State private var atBottom = true
    @State private var reachedStart = false
    @FocusState private var composerFocused: Bool

    private var key: String { "g:\(gid)" }

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
        var msgs = engine.threads[key] ?? []
        if !engine.blocked.isEmpty { msgs.removeAll { engine.isBlocked($0.sender) } }      // hidden, not deleted
        var out: [Item] = []
        out.reserveCapacity(msgs.count + 8)
        let cal = Calendar.current
        for (i, m) in msgs.enumerated() {
            if i == 0 || !cal.isDate(msgs[i - 1].sentAt, inSameDayAs: m.sentAt) { out.append(.day(cal.startOfDay(for: m.sentAt))) }
            let prev = i > 0 ? msgs[i - 1] : nil, next = i + 1 < msgs.count ? msgs[i + 1] : nil
            func same(_ o: Message?) -> Bool {
                guard let o else { return false }
                return o.outgoing == m.outgoing && o.sender == m.sender && o.kind != .system && o.kind != .call
                    && abs(o.sentAt.timeIntervalSince(m.sentAt)) < 180 && cal.isDate(o.sentAt, inSameDayAs: m.sentAt)
            }
            out.append(.message(m, first: !same(prev), last: !same(next)))
        }
        return out
    }

    var body: some View {
        if let g = engine.groups.groups[gid] {
            content(g)
        } else {
            EmptyStateView(icon: "person.3", title: "Group not found", message: "This group is no longer on this iPhone.")
        }
    }

    private func content(_ g: PrivaGroup) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    GroupHeaderSection(group: g, me: engine.me) { showInfo = true }
                        .onAppear { if !reachedStart { reachedStart = !engine.loadOlder(key) } }
                    ForEach(items) { item in
                        switch item {
                        case .day(let d):
                            Text(Format.day.string(from: d)).font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                                .padding(.vertical, 10)
                        case .message(let m, let first, let last):
                            MessageRow(message: m, groupFirst: first, groupLast: last,
                                       onOpen: { viewing = m }, onInfo: { infoFor = m },
                                       senderName: m.outgoing ? nil : engine.name(of: m.sender ?? g.host, in: g),
                                       onDeleteForEveryone: canDeleteForEveryone(m, in: g) ? { engine.groups.perform(.deleteMessage(id: m.id), in: gid) } : nil)
                                .id(m.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    Color.clear.frame(height: 6).id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 12)
                .animation(Theme.snappy, value: engine.threads[key]?.count)
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
            .onChange(of: engine.threads[key]?.last?.id) { _, _ in
                engine.markRead(key)
                if atBottom || engine.threads[key]?.last?.outgoing == true {
                    withAnimation(Theme.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let reason = postingBlocked(g) {
                    Label(reason, systemImage: g.ended ? "archivebox" : "lock")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                } else {
                    ComposerBar(text: $draft, focused: $composerFocused, preparing: preparing > 0,
                                onSend: send, onPhotos: { original in pickOriginal = original; showPicker = true },
                                onFiles: { showFiles = true })
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showInfo = true } label: { GroupTitle(group: g) }.buttonStyle(.plain)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Group voice call", systemImage: "phone.fill") { engine.groupCalls.start(gid: gid, video: false) }
                    .disabled(g.ended || g.members.count < 2)
                Button("Group video call", systemImage: "video.fill") { engine.groupCalls.start(gid: gid, video: true) }
                    .disabled(g.ended || g.members.count < 2)
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
        .onAppear { _ = engine.loadThread(key); engine.openChat = key }
        .onDisappear { if engine.openChat == key { engine.openChat = nil } }
        .fullScreenCover(item: $viewing) { m in MediaViewer(message: m).environment(engine) }
        .sheet(item: $infoFor) { m in MessageInfoSheet(message: m).presentationDetents([.medium]) }
        .sheet(isPresented: $showInfo) { NavigationStack { GroupInfoView(gid: gid) }.environment(engine) }
    }

    private func postingBlocked(_ g: PrivaGroup) -> String? {
        if g.ended { return "This group has ended" }
        if g.isMuted(engine.me) { return "An admin muted you in this group" }
        if g.rules.announceOnly && !g.isAdmin(engine.me) { return "Only admins can post in this group" }
        return nil
    }

    private func canDeleteForEveryone(_ m: Message, in g: PrivaGroup) -> Bool {
        guard !g.ended, m.kind == .text || m.kind == .media, m.seq != nil || g.host == engine.me else { return false }
        return g.isAdmin(engine.me) || m.outgoing
    }

    private func send() {
        let text = draft
        draft = ""
        if !engine.groups.post(text: text, to: gid) { draft = text }
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
                    await engine.groups.post(media: prepared, to: gid)
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
                await engine.groups.post(media: prepared, to: gid)
            }
        }
    }
}

struct GroupTitle: View {
    @Environment(PrivaEngine.self) private var engine
    let group: PrivaGroup

    var body: some View {
        HStack(spacing: 10) {
            GroupAvatar(name: group.name, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(hostOnline ? Theme.mint : Theme.textSecondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows members, rules and admin tools")
    }

    private var hostOnline: Bool { group.host == engine.me || engine.presence[group.host] == .online }

    private var subtitle: String {
        if group.ended { return "ended" }
        let host = group.host == engine.me ? "hosted by you" : "host \(hostOnline ? "online" : "offline")"
        return "\(group.memberCountText) · \(host)"
    }
}

struct GroupHeaderSection: View {
    @Environment(PrivaEngine.self) private var engine
    let group: PrivaGroup
    let me: String
    let onInfo: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            SecureChip(text: group.host == me ? "End-to-end encrypted · hosted by you" : "End-to-end encrypted · hosted by \(engine.name(of: group.host, in: group))")
            Button("Members & rules", systemImage: "person.3", action: onInfo).font(.caption.weight(.semibold)).buttonStyle(.glass)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - Group info & admin

struct GroupInfoView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let gid: String
    @State private var renaming = false
    @State private var newName = ""
    @State private var adding = false
    @State private var confirmLeave = false
    @State private var confirmDisband = false
    @State private var confirmDelete = false
    @State private var removing: PrivaGroup.Member?
    @State private var handingTo: PrivaGroup.Member?
    @State private var blocking: String?
    @State private var reporting: String?

    var body: some View {
        Group {
            if let g = engine.groups.groups[gid] { list(g) } else { EmptyStateView(icon: "person.3", title: "Group not found", message: "") }
        }
        .navigationTitle("Group info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func list(_ g: PrivaGroup) -> some View {
        let me = engine.me
        let admin = g.isAdmin(me) && !g.ended
        let isHost = g.host == me
        return List {
            Section {
                VStack(spacing: 10) {
                    GroupAvatar(name: g.name, size: 84)
                    Text(g.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                    Text(isHost ? "Hosted by you" : "Hosted on \(engine.name(of: g.host, in: g))'s iPhone").font(.subheadline).foregroundStyle(Theme.textSecondary)
                    if !g.ended {
                        HStack(spacing: 12) {
                            Button("Voice", systemImage: "phone.fill") { dismiss(); engine.groupCalls.start(gid: gid, video: false) }
                            Button("Video", systemImage: "video.fill") { dismiss(); engine.groupCalls.start(gid: gid, video: true) }
                        }
                        .buttonStyle(.glass)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            if admin {
                Section {
                    Button("Rename group", systemImage: "pencil") { newName = g.name; renaming = true }
                }
            }

            Section {
                ForEach(sortedMembers(g)) { m in memberRow(m, in: g) }
                if admin {
                    Button("Add members", systemImage: "person.badge.plus") { adding = true }
                }
            } header: {
                Text("Members · \(g.members.count)")
            } footer: {
                if let next = g.successors.first(where: { $0 != g.host }) {
                    Text("If the host leaves Priva, \(engine.name(of: next, in: g)) takes over.")
                }
            }

            Section("Rules") {
                if admin {
                    Toggle("Only admins can post", isOn: Binding(get: { g.rules.announceOnly }, set: { v in
                        var r = g.rules
                        r.announceOnly = v
                        engine.groups.perform(.rules(r), in: gid)
                    }))
                    NavigationLink { KeywordFilterView(gid: gid) } label: {
                        LabeledContent("Keyword filter", value: g.rules.keywords.isEmpty ? "Off" : "\(g.rules.keywords.count) words")
                    }
                } else {
                    LabeledContent("Who can post", value: g.rules.announceOnly ? "Admins only" : "Everyone")
                    LabeledContent("Keyword filter", value: g.rules.keywords.isEmpty ? "Off" : "On · \(g.rules.filterAction == .block ? "blocks messages" : "hides words")")
                }
            }

            Section {
                if g.ended {
                    Button("Delete group", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } else if isHost {
                    Button("End group for everyone", systemImage: "xmark.octagon", role: .destructive) { confirmDisband = true }
                } else {
                    Button("Leave group", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLeave = true }
                }
            } footer: {
                if g.ended {
                    EmptyView()
                } else if isHost {
                    Text("To leave, make someone else the host first.")
                } else {
                    Text("The host's iPhone relays this group's messages and calls and can read them.")
                }
            }
        }
        .alert("Rename group", isPresented: $renaming) {
            TextField("Group name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { engine.groups.perform(.rename(newName), in: gid) }
        }
        .sheet(isPresented: $adding) { AddMembersSheet(gid: gid).environment(engine) }
        .confirmationDialog("Leave \(g.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave group", role: .destructive) { engine.groups.perform(.leave, in: gid); dismiss() }
        } message: { Text("You'll stop receiving messages.") }
        .confirmationDialog("Delete \(g.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete group", role: .destructive) { dismiss(); engine.groups.forget(gid) }
        } message: { Text("Its messages are removed from this iPhone.") }
        .confirmationDialog("End \(g.name) for everyone?", isPresented: $confirmDisband, titleVisibility: .visible) {
            Button("End group", role: .destructive) { engine.groups.perform(.disband, in: gid); dismiss() }
        } message: { Text("Nobody will be able to post again.") }
        .confirmationDialog("Remove \(removing.map { engine.name(of: $0.username, in: g) } ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove from group", role: .destructive) {
                if let m = removing { engine.groups.perform(.remove(username: m.username), in: gid) }
                removing = nil
            }
        }
        .confirmationDialog("Make \(handingTo.map { engine.name(of: $0.username, in: g) } ?? "") the host?", isPresented: Binding(get: { handingTo != nil }, set: { if !$0 { handingTo = nil } }), titleVisibility: .visible) {
            Button("Transfer hosting") {
                if let m = handingTo { engine.groups.perform(.transferHost(to: m.username), in: gid) }
                handingTo = nil
            }
        } message: { Text("Their iPhone will relay the group from now on. You'll become an admin.") }
        .blockConfirmation(blocking, isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }))
        .sheet(item: Binding(get: { reporting.map(ReportTarget.init) }, set: { reporting = $0?.id })) { t in
            ReportSheet(username: t.id, place: "Group “\(g.name)”",
                        candidates: engine.loadThread(g.threadKey).filter { $0.sender == t.id && $0.kind != .system })
                .environment(engine)
        }
    }

    private struct ReportTarget: Identifiable { let id: String }

    private func sortedMembers(_ g: PrivaGroup) -> [PrivaGroup.Member] {
        func rank(_ r: PrivaGroup.Role) -> Int { r == .host ? 0 : r == .admin ? 1 : 2 }
        return g.members.sorted { (rank($0.role), $0.joined) < (rank($1.role), $1.joined) }
    }

    @ViewBuilder private func memberRow(_ m: PrivaGroup.Member, in g: PrivaGroup) -> some View {
        let me = engine.me
        let isHost = g.host == me
        let canModerate = g.isAdmin(me) && !g.ended && m.username != me && m.role != .host && (isHost || m.role == .member)
        HStack(spacing: 12) {
            Avatar(name: m.username, size: 40, online: m.username != me && engine.presence[m.username] == .online)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(engine.name(of: m.username, in: g)).font(.body.weight(.semibold)).lineLimit(1)
                    if m.muted { Image(systemName: "speaker.slash.fill").font(.caption).foregroundStyle(Theme.amber).accessibilityLabel("Muted") }
                }
                if m.username == me || engine.name(of: m.username, in: g) != m.username {
                    Text(m.username == me ? "@\(m.username) · you" : "@\(m.username)").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            RoleBadge(role: m.role)
            if m.username != me {
                Menu {
                    if isHost && m.username != me {
                        if m.role == .admin {
                            Button("Remove admin", systemImage: "shield.slash") { engine.groups.perform(.demote(username: m.username), in: gid) }
                        } else {
                            Button("Make admin", systemImage: "shield.lefthalf.filled") { engine.groups.perform(.promote(username: m.username), in: gid) }
                        }
                        Button("Make host", systemImage: "crown") { handingTo = m }
                    }
                    if canModerate {
                        Button(m.muted ? "Unmute" : "Mute", systemImage: m.muted ? "speaker.wave.2" : "speaker.slash") {
                            engine.groups.perform(.mute(username: m.username, on: !m.muted), in: gid)
                        }
                        Button("Remove from group", systemImage: "person.fill.xmark", role: .destructive) { removing = m }
                    }
                    Divider()
                    if engine.isBlocked(m.username) {
                        Button("Unblock", systemImage: "hand.raised.slash") { engine.unblock(m.username) }
                    } else {
                        Button("Block", systemImage: "hand.raised.fill", role: .destructive) { blocking = m.username }
                    }
                    Button("Report", systemImage: "exclamationmark.bubble.fill", role: .destructive) { reporting = m.username }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.textSecondary).frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Actions for \(engine.name(of: m.username, in: g))")
            }
        }
    }
}

struct AddMembersSheet: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let gid: String
    @State private var selected: Set<String> = []

    var body: some View {
        let g = engine.groups.groups[gid]
        let candidates = engine.friends.filter { g?.member($0.username) == nil }
        NavigationStack {
            List(candidates) { c in
                Button {
                    if selected.contains(c.username) { selected.remove(c.username) } else { selected.insert(c.username) }
                } label: {
                    HStack(spacing: 12) {
                        Avatar(name: c.username, size: 38)
                        Text(c.displayName).font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: selected.contains(c.username) ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(selected.contains(c.username) ? Theme.violet : Theme.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityAddTraits(selected.contains(c.username) ? .isSelected : [])
            }
            .overlay {
                if candidates.isEmpty { EmptyStateView(icon: "person.2", title: "Everyone's here", message: "All your friends are in this group.") }
            }
            .navigationTitle("Add members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Invite") {
                        for u in selected { engine.groups.invite(u, to: gid) }
                        engine.toast = .init(title: "Invites sent", body: "They'll join once they accept.", contact: nil)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

struct KeywordFilterView: View {
    @Environment(PrivaEngine.self) private var engine
    let gid: String
    @State private var rules = PrivaGroup.Rules()
    @State private var newWord = ""
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add a word or phrase", text: $newWord)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(rules.keywords, id: \.self) { w in Text(w) }
                    .onDelete { rules.keywords.remove(atOffsets: $0); save() }
            } footer: {
                Text("Matches whole words, ignoring case and accents.")
            }
            Section("When a message matches") {
                Picker("Action", selection: Binding(get: { rules.filterAction }, set: { rules.filterAction = $0; save() })) {
                    Text("Block the message").tag(PrivaGroup.FilterAction.block)
                    Text("Mask the word (•••)").tag(PrivaGroup.FilterAction.mask)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .navigationTitle("Keyword filter")
        .onAppear {
            guard !loaded, let g = engine.groups.groups[gid] else { return }
            loaded = true
            rules = g.rules
        }
    }

    private func add() {
        let w = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !rules.keywords.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { newWord = ""; return }
        rules.keywords.append(String(w.prefix(60)))
        newWord = ""
        save()
    }

    private func save() { engine.groups.perform(.rules(rules), in: gid) }
}
