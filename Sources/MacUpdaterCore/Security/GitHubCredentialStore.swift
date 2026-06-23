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

    /// Keychain `SecItemAdd` attributes for storing the PAT.
    ///
    /// Accessibility is `AfterFirstUnlockThisDeviceOnly`:
    /// - *AfterFirstUnlock* (not `WhenUnlocked`) is required because the token is read
    ///   by the **scheduled background menu-bar check** (`MenuBarUpdateChecker` →
    ///   `GitHubReleasesChecker` / `WegaSelfUpdateChecker`) with no user present.
    /// - *ThisDeviceOnly* keeps the credential off iCloud Keychain sync and device
    ///   backups, so the PAT can't leak to another machine.
    ///
    /// Deliberately **no** `kSecAttrAccessControl` (Sonar S6288): the only thing that
    /// rule accepts is a user-presence requirement (Touch ID / passcode) on every read,
    /// which would pop an auth prompt during silent background scans — or fail the read
    /// and drop the token entirely, defeating its sole purpose (lifting the read-only
    /// GitHub rate limit 60→5000 req/h). Suppressed with this rationale in
    /// `sonar-project.properties`.
    static func writeAttributes(data: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    /// Stores (replacing) the token. Empty input clears it. Returns success.
    @discardableResult
    public static func setToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        clear()
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return trimmed.isEmpty }
        return SecItemAdd(writeAttributes(data: data) as CFDictionary, nil) == errSecSuccess
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
