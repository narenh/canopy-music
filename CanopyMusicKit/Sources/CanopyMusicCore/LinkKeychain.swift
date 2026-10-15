import Foundation
import Security

/// The hub's cmdlp API token, in this device's Keychain (iPad, Mac, or Apple TV). Never logged,
/// and never in a snapshot or a page: the host sees only its last four characters.
public struct KeychainLinkTokenStore: LinkTokenStore {
    public let service: String

    public init(service: String = "com.canopysf.CanopyMusic.cmdlpToken") {
        self.service = service
    }

    public func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    /// nil forgets it.
    public func save(_ token: String?) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        guard let token, !token.isEmpty else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: Data(token.utf8),
            // The hub plays all night: it reads the token after a relaunch with the screen locked.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }
}
