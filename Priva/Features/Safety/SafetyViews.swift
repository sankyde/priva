import MessageUI
import SwiftUI
import UniformTypeIdentifiers

/// Where reports and support requests go: `PrivaSupportEmail` in Info.plist (project.yml). scripts/launch_check.sh
/// fails while it's unset.
enum Support {
    static var email: String? {
        (Bundle.main.object(forInfoDictionaryKey: "PrivaSupportEmail") as? String).flatMap { $0.contains("@") ? $0 : nil }
    }
    static var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// A report about another user. Contains only what the reporter chose to include: never the reporter's own username,
/// keys or messages. Messages are end-to-end encrypted, so a report is the only way Priva's team ever sees any.
struct AbuseReport {
    enum Reason: String, CaseIterable, Identifiable {
        case spam = "Spam or scam"
        case harassment = "Harassment or threats"
        case sexual = "Sexual or violent content"
        case illegal = "Illegal content or activity"
        case impersonation = "Pretending to be someone else"
        case other = "Something else"
        var id: String { rawValue }
    }

    let username: String
    let place: String
    var reason: Reason = .harassment
    var details = ""
    var evidence: [Message] = []
    let id = String(UUID().uuidString.prefix(8)).lowercased()

    var subject: String { "Priva report \(id): @\(username)" }

    var body: String {
        var lines = ["Reported username: @\(username)", "Reason: \(reason.rawValue)", "Where: \(place)"]
        let d = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { lines.append("Details: \(d)") }
        if !evidence.isEmpty {
            lines.append("")
            lines.append("Their messages, included by the reporter:")
            let f = ISO8601DateFormatter()
            for m in evidence {
                let what = m.text.map { String($0.prefix(600)) } ?? "[\(m.attachment?.kind.rawValue ?? "attachment"): \(m.attachment?.name ?? "")]"
                lines.append("[\(f.string(from: m.sentAt))] \(what)")
            }
        }
        lines += ["", "Report \(id) · Priva \(Support.version)"]
        return lines.joined(separator: "\n")
    }
}

struct ReportSheet: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let username: String
    /// Their most recent messages the reporter may attach (newest last).
    let candidates: [Message]
    var onBlocked: (() -> Void)?
    @State private var report: AbuseReport
    @State private var include = true
    @State private var alsoBlock = true
    @State private var composing = false
    @State private var copiedTo: String?

    init(username: String, place: String, candidates: [Message], onBlocked: (() -> Void)? = nil) {
        self.username = username
        self.candidates = Array(candidates.suffix(10))
        self.onBlocked = onBlocked
        _report = State(initialValue: AbuseReport(username: username, place: place))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What happened?") {
                    Picker("Reason", selection: $report.reason) {
                        ForEach(AbuseReport.Reason.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    TextField("Anything that helps (optional)", text: $report.details, axis: .vertical).lineLimit(2...6)
                }
                if !candidates.isEmpty {
                    Section {
                        Toggle("Include their last \(candidates.count == 1 ? "message" : "\(candidates.count) messages")", isOn: $include)
                        if include {
                            ForEach(candidates) { m in
                                Text(m.text ?? "[\(m.attachment?.name ?? "attachment")]").font(.footnote).lineLimit(3)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    } footer: {
                        Text("Sent from your email app, so Priva sees your email address and only what you include here.")
                    }
                }
                Section {
                    Toggle("Also block @\(username)", isOn: $alsoBlock)
                }
                Section {
                    Button("Send report", systemImage: "exclamationmark.bubble.fill", action: send)
                        .accessibilityIdentifier("report.send")
                } footer: {
                    Text("Reviewed within 24 hours. Accounts that break the Terms are removed.")
                }
            }
            .navigationTitle("Report @\(username)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $composing) {
                MailComposer(to: Support.email ?? "", subject: report.subject, body: filled.body) { sent in
                    composing = false
                    if sent { finish() }
                }
                .ignoresSafeArea()
            }
            .alert("Report copied", isPresented: Binding(get: { copiedTo != nil }, set: { if !$0 { copiedTo = nil } })) {
                Button("OK") { finish() }
            } message: {
                Text(copiedTo.map { "No mail account is set up on this iPhone. Paste the report into an email to \($0)." }
                     ?? "Paste it wherever you'd like to report this.")
            }
        }
    }

    private var filled: AbuseReport {
        var r = report
        r.evidence = include ? candidates : []
        return r
    }

    private func send() {
        let r = filled
        guard let to = Support.email else { copy(r, to: nil); return }
        if MFMailComposeViewController.canSendMail() { composing = true; return }
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = to
        c.queryItems = [URLQueryItem(name: "subject", value: r.subject), URLQueryItem(name: "body", value: r.body)]
        guard let url = c.url else { copy(r, to: to); return }
        openURL(url) { opened in if opened { finish() } else { copy(r, to: to) } }
    }

    /// Last resort: the report on the clipboard, this iPhone only, and gone after five minutes.
    private func copy(_ r: AbuseReport, to: String?) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: r.subject + "\n\n" + r.body]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
        copiedTo = to ?? ""
    }

    private func finish() {
        if alsoBlock {
            engine.block(username)
            onBlocked?()
        }
        dismiss()
    }
}

struct MailComposer: UIViewControllerRepresentable {
    let to: String
    let subject: String
    let body: String
    let done: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([to])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let done: (Bool) -> Void
        init(done: @escaping (Bool) -> Void) { self.done = done }
        nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            let sent = result == .sent || result == .saved
            Task { @MainActor in self.done(sent) }
        }
    }
}

extension View {
    /// "Block @name?" with what blocking does, then blocks.
    func blockConfirmation(_ username: String?, isPresented: Binding<Bool>, onBlocked: @escaping () -> Void = {}) -> some View {
        modifier(BlockConfirmation(username: username, isPresented: isPresented, onBlocked: onBlocked))
    }
}

private struct BlockConfirmation: ViewModifier {
    @Environment(PrivaEngine.self) private var engine
    let username: String?
    @Binding var isPresented: Bool
    let onBlocked: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Block @\(username ?? "")?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                guard let username else { return }
                engine.block(username)
                onBlocked()
            }
        } message: {
            Text("They can't message, call or invite you, and aren't told. Your chat with them is deleted.")
        }
    }
}

struct BlockedListView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        List {
            if engine.blocked.isEmpty {
                ContentUnavailableView("Nobody blocked", systemImage: "hand.raised",
                                       description: Text("Block someone from their profile, a friend request or a group's member list."))
                    .listRowBackground(Color.clear)
            }
            ForEach(engine.blocked.sorted { $0.at > $1.at }) { b in
                // At accessibility sizes the button goes under the name instead of breaking into "Un blo ck".
                let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    HStack(spacing: 12) {
                        Avatar(name: b.username, size: 40).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("@\(b.username)").font(.body.weight(.semibold))
                            Text("Blocked \(b.at.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if !size.isAccessibilitySize { Spacer() }
                    Button("Unblock") { engine.unblock(b.username) }.buttonStyle(.glass).lineLimit(1)
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Terms and privacy policy (bundled, readable offline)

enum LegalDocument: String, Identifiable {
    case terms = "Terms"
    case privacy = "Privacy"
    var id: String { rawValue }
    var title: String { self == .terms ? "Terms of Use" : "Privacy Policy" }
}

struct LegalView: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(Self.blocks(document).enumerated()), id: \.offset) { _, b in b }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    /// The bundled Markdown, one view per line: headings, bullets and paragraphs (inline emphasis and links kept).
    static func blocks(_ doc: LegalDocument) -> [AnyView] {
        guard let url = Bundle.main.url(forResource: doc.rawValue, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [AnyView(Text("Unavailable."))] }
        func inline(_ s: String) -> Text {
            let email = Support.email ?? "the support address on Priva's App Store page"
            let s = s.replacingOccurrences(of: "{{SUPPORT_EMAIL}}", with: email)
            return Text((try? AttributedString(markdown: s)) ?? AttributedString(s))
        }
        return text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("# ") { return nil }          // the title is in the navigation bar
            if line.hasPrefix("## ") { return AnyView(inline(String(line.dropFirst(3))).font(.headline).padding(.top, 10)) }
            if line.hasPrefix("- ") {
                return AnyView(HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(Theme.textSecondary)
                    inline(String(line.dropFirst(2))).font(.subheadline)
                })
            }
            return AnyView(inline(line).font(.subheadline).foregroundStyle(Theme.textPrimary))
        }
    }
}
