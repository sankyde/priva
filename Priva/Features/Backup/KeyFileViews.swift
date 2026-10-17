import SwiftUI
import UniformTypeIdentifiers

/// A sealed key file (KeyFile) as a document for "Save to Files".
nonisolated struct KeyFileDocument: FileDocument {
    static let type = UTType(exportedAs: "com.sanketdesai.priva.key")
    static var readableContentTypes: [UTType] { [type] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents, d.count <= KeyFile.maxSize else { throw CocoaError(.fileReadCorruptFile) }
        data = d
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension KeyFile {
    /// Seals `secret` with the password and this Apple Account's purchase (scrypt runs off the main thread).
    /// `fallbackID`: the vault's saved purchase ID, used if the App Store can't be asked right now.
    static func document(_ secret: Data, kind: Kind, password: String, fallbackID: String? = nil) async throws -> KeyFileDocument {
        guard let id = (try? await PurchaseService.purchaseID()) ?? fallbackID else { throw PurchaseService.Failure.notPurchased }
        let s = secret
        let data = try await Task.detached(priority: .userInitiated) {
            try seal(s, kind: kind, password: password, purchaseID: id)
        }.value
        return KeyFileDocument(data: data)
    }

    /// Reads a file the user picked and opens it with the password and a purchase ID: this Apple Account's, then the
    /// ones saved in the vault, then one the user typed in.
    static func open(url: URL, kind: Kind, password: String, savedIDs: [String] = [], typedID: String? = nil) async throws -> Data {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? .max) <= maxSize else { throw Failure.notAKeyFile }
        let file = try Data(contentsOf: url)
        _ = try peek(file)
        let live = try? await PurchaseService.purchaseID()
        var ids: [String] = []
        for id in [live] + savedIDs.map(Optional.some) + [typedID.map(normalized)] {
            if let id, !id.isEmpty, !ids.contains(id) { ids.append(id) }
        }
        guard !ids.isEmpty else { throw PurchaseService.Failure.notPurchased }
        let candidates = ids
        return try await Task.detached(priority: .userInitiated) {
            try open(file, expecting: kind, password: password, purchaseIDs: candidates)
        }.value
    }

    static func message(for error: Error) -> String {
        switch error {
        case Failure.wrongKind(.backup): "That's your Backup Key file. Choose your recovery phrase file."
        case Failure.wrongKind(.recovery): "That's your recovery phrase file. Choose your Backup Key file."
        case Failure.wrongPasswordOrAccount:
            "Wrong password or Apple Account. Use the password you saved it with, or the purchase ID."
        case PurchaseService.Failure.notPurchased:
            "Couldn't check this Apple Account's purchase. Enter the purchase ID instead."
        case Failure.notAKeyFile, is CocoaError: "That file isn't a Priva key file."
        default: "Something went wrong. Try again."
        }
    }
}

extension View {
    /// "Save to Files" for a sealed key; `onSaved` runs once the file is actually written. A failure (not a cancel) is
    /// reported through `onFailed`, never a silent stop.
    func keyFileExporter(_ document: Binding<KeyFileDocument?>, kind: KeyFile.Kind, onSaved: @escaping () -> Void,
                         onFailed: @escaping () -> Void = {}) -> some View {
        fileExporter(isPresented: Binding(get: { document.wrappedValue != nil }, set: { if !$0 { document.wrappedValue = nil } }),
                     document: document.wrappedValue, contentType: KeyFileDocument.type,
                     defaultFilename: KeyFile.fileName(kind)) { result in
            document.wrappedValue = nil
            switch result {
            case .success: onSaved()
            case .failure(let e): if (e as? CocoaError)?.code != .userCancelled { onFailed() }
            }
        }
    }

    /// Picks a key file, asks for the password it was saved with and hands back the 32-byte key.
    /// `password`: the screen's own password field, used when it's filled, and filled in when asked for.
    /// `savedIDs`: purchase IDs from the unlocked vault (empty before sign-in).
    func keyFileImporter(isPresented: Binding<Bool>, kind: KeyFile.Kind, password: Binding<String>? = nil,
                         savedIDs: [String] = [], onOpen: @escaping (Data) -> Void) -> some View {
        modifier(KeyFileImporter(isPresented: isPresented, kind: kind, password: password, savedIDs: savedIDs, onOpen: onOpen))
    }
}

private struct KeyFileImporter: ViewModifier {
    @Binding var isPresented: Bool
    let kind: KeyFile.Kind
    let password: Binding<String>?
    let savedIDs: [String]
    let onOpen: (Data) -> Void
    @State private var picked: URL?
    @State private var asking = false
    @State private var typed = ""
    @State private var askingID = false
    @State private var typedID = ""
    /// The password of the last failed try, for a retry with a typed purchase ID.
    @State private var lastPassword: String?
    @State private var busy = false
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [KeyFileDocument.type, .data]) { result in
                guard case .success(let url) = result else { return }
                picked = url
                lastPassword = nil
                if let pw = password?.wrappedValue, !pw.isEmpty { Task { await open(pw) }; return }
                askPassword()
            }
            .alert("Enter your Priva password", isPresented: $asking) {
                SecureField("Password", text: $typed)
                    .textContentType(.oneTimeCode)
                Button("Cancel", role: .cancel) { finish() }
                Button("Open") { let pw = typed; typed = ""; Task { await open(pw) } }
            } message: {
                Text("The one you had when you saved this file.")
            }
            .alert("Enter the purchase ID", isPresented: $askingID) {
                TextField("Purchase ID", text: $typedID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { finish() }
                Button("Open") { let id = typedID; typedID = ""; Task { await open(lastPassword ?? "", typedID: id) } }
            } message: {
                Text("Settings › Security & account › Purchase ID on the iPhone where you saved the file.")
            }
            .alert("Couldn't open the file", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                if lastPassword != nil {
                    Button("Try another password") { askPassword() }
                    Button("Enter purchase ID…") { askingID = true }
                }
                Button(lastPassword != nil ? "Cancel" : "OK", role: .cancel) { finish() }
            } message: {
                Text(error ?? "")
            }
            .overlay {
                if busy {
                    ProgressView("Opening…").padding(24).glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
            }
    }

    private func askPassword() {
        #if DEBUG
        if let pw = DebugAutomation.testPassword { typed = pw }
        #endif
        asking = true
    }

    private func finish() {
        picked = nil
        lastPassword = nil
        typed = ""
        typedID = ""
    }

    private func open(_ pw: String, typedID: String? = nil) async {
        guard let url = picked else { return }
        busy = true
        defer { busy = false }
        do {
            let secret = try await KeyFile.open(url: url, kind: kind, password: pw, savedIDs: savedIDs, typedID: typedID)
            if let password, password.wrappedValue.isEmpty { password.wrappedValue = pw }
            finish()
            onOpen(secret)
        } catch KeyFile.Failure.wrongPasswordOrAccount {
            lastPassword = pw          // the file is fine: offer another password or a purchase ID
            self.error = KeyFile.message(for: KeyFile.Failure.wrongPasswordOrAccount)
        } catch PurchaseService.Failure.notPurchased {
            lastPassword = pw
            self.error = KeyFile.message(for: PurchaseService.Failure.notPurchased)
        } catch {
            finish()
            self.error = KeyFile.message(for: error)
        }
    }
}

/// "Save as encrypted file" with the one-line promise of what it takes to open it.
struct SaveKeyFileButton: View {
    let kind: KeyFile.Kind
    var busy = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            SecondaryButton(title: busy ? "Encrypting…" : "Save as file", systemImage: "arrow.down.doc.fill", action: action)
                .disabled(busy)
                .accessibilityIdentifier("keyfile.save.\(kind.rawValue)")
            Text("Encrypted with your password and Apple Account.")
                .font(.caption).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
        }
    }
}

/// "Open my … file" next to a 24-word input.
struct OpenKeyFileButton: View {
    let kind: KeyFile.Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(kind == .recovery ? "Open my recovery phrase file" : "Open my Backup Key file", systemImage: "doc.badge.arrow.up.fill")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
        .tint(Theme.violet)
        .accessibilityIdentifier("keyfile.open.\(kind.rawValue)")
    }
}

/// How a 24-word key is kept the first time it's shown: "I've written it down" (one last warning, with a way back)
/// or "Save as file" (asks for the password, then saves the encrypted file). No word quiz.
struct KeepKeyButtons: View {
    let kind: KeyFile.Kind
    let secret: Data
    /// What the file is sealed with. What's typed must match, so a typo can't make a file nobody can open.
    let password: String
    var fallbackID: String?
    let onKept: () -> Void
    @State private var confirming = false
    @State private var asking = false
    @State private var typed = ""
    @State private var sealing = false
    @State private var document: KeyFileDocument?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 10) {
            if let error {
                Text(error).font(.footnote.weight(.medium)).foregroundStyle(Theme.rose).multilineTextAlignment(.center)
            }
            PrimaryButton(title: "I've written it down") { confirming = true }
                .accessibilityIdentifier("keep.written")
            SaveKeyFileButton(kind: kind, busy: sealing) {
                error = nil
                #if DEBUG
                if let pw = DebugAutomation.testPassword { typed = pw }
                #endif
                asking = true
            }
        }
        .alert(kind == .backup ? "Shown only once" : "Written it down?", isPresented: $confirming) {
            Button("Go back", role: .cancel) {}
            Button("I've written it down") { onKept() }
        } message: {
            Text(kind == .backup ? "Without these words, your backups can't be opened."
                                 : "You'll need these words if you forget your password.")
        }
        .alert("Enter your password", isPresented: $asking) {
            SecureField("Password", text: $typed)
                .textContentType(.oneTimeCode)
            Button("Cancel", role: .cancel) { typed = "" }
            Button("Save") { let pw = typed; typed = ""; Task { await seal(pw) } }
        } message: {
            Text("The file opens only with it.")
        }
        .keyFileExporter($document, kind: kind, onSaved: onKept, onFailed: { error = "Couldn't save the file. Try again." })
    }

    private func seal(_ typed: String) async {
        guard !password.isEmpty, typed == password else { error = "That isn't your Priva password."; return }
        sealing = true
        defer { sealing = false }
        do {
            document = try await KeyFile.document(secret, kind: kind, password: typed, fallbackID: fallbackID)
        } catch {
            self.error = KeyFile.message(for: error)
        }
    }
}
