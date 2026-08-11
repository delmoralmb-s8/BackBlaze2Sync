import Foundation
import Security

/// A B2 connection's raw Key ID + Application Key — normally the app only hands these to
/// `rclone config create` and never keeps them, but generating a forced-download link needs
/// them again (see B2API.swift), so they're saved here once, in the Keychain, per remote.
struct B2Credentials: Codable {
    let accountID: String
    let appKey: String
}

enum B2CredentialsStore {
    private static let service = "mx.smh.backblaze2sync.b2creds"

    static func save(_ creds: B2Credentials, for remoteName: String) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: remoteName
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete(for remoteName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: remoteName
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func load(for remoteName: String) -> B2Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: remoteName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(B2Credentials.self, from: data)
    }
}
