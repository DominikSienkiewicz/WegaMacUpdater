import Foundation
import Security

/// Keychain-backed storage for an optional GitHub Personal Access Token
/// (**SEC-08 / C1**). A token lifts the REST limit from 60→5000 req/h **and**
/// makes conditional `304` responses exempt from the primary rate limit (the
/// exemption GitHub documents only for *authorized* requests).
///
/// Stored in the Keychain (NEVER `UserDefaults`): a PAT is a credential.
public enum GitHubCredentialStore {
    private static let service = "com.wega.WegaMacUpdater.github"
    private static let account = "github-pat"

    public static func token() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    public static var hasToken: Bool { token() != nil }

    /// Stores (replacing) the token. Empty input clears it. Returns success.
    @discardableResult
    public static func setToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        clear()
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return trimmed.isEmpty }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Builds GitHub request headers, adding `Authorization: Bearer` when a PAT is
/// configured. Centralized so every GitHub call site (releases checker, self-update)
/// authenticates consistently.
public enum GitHubAuth {
    public static func headers(accept: String = "application/vnd.github+json") -> [String: String] {
        var headers = ["Accept": accept]
        if let token = GitHubCredentialStore.token() {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }
}
