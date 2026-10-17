import Foundation
import LocalAuthentication
import Security

/// Device-bound Keychain storage. Nothing here ever syncs to iCloud or appears in backups.
nonisolated enum Keychain {
    static let service = "com.priva.app.vault"

    enum Failure: Error { case status(OSStatus) }

    /// Plain items are updated in place: deleting first and re-adding would leave a window in which a killed app
    /// loses the item (for `vault.meta`, the whole account). Access-controlled items are replaced (new policy).
    static func set(_ data: Data, account: String, accessControl: SecAccessControl? = nil,
                    context: LAContext? = nil) throws {
        if accessControl == nil {
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecSuccess { return }
            guard status == errSecItemNotFound else { throw Failure.status(status) }
        } else {
            delete(account)
        }
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        if let accessControl {
            q[kSecAttrAccessControl as String] = accessControl
        } else {
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        if let context { q[kSecUseAuthenticationContext as String] = context }
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    static func get(_ account: String, context: LAContext? = nil) throws -> Data? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let context { q[kSecUseAuthenticationContext as String] = context }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.status(status) }
        return out as? Data
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }

    static func deleteAll() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
    }

    static func setCodable<T: Encodable>(_ v: T, account: String) throws {
        try set(try JSONEncoder().encode(v), account: account)
    }

    static func getCodable<T: Decodable>(_ t: T.Type, account: String) -> T? {
        guard let d = try? get(account) else { return nil }
        return try? JSONDecoder().decode(t, from: d)
    }
}
