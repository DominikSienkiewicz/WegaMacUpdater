import XCTest
import Security
@testable import MacUpdaterCore

/// Pins the keychain security posture for the GitHub PAT (Sonar S6288). The token is
/// read in automated/background scans (the scheduled menu-bar check), so it must NOT
/// require per-read user authentication — and it must not sync off-device.
final class GitHubCredentialStoreTests: XCTestCase {
    private let attrs = GitHubCredentialStore.writeAttributes(data: Data("pat".utf8))

    func testStoredAsGenericPasswordInKeychain() {
        XCTAssertEqual(attrs[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }

    // Accessibility must be `AfterFirstUnlockThisDeviceOnly`: readable by a background
    // process after first unlock, but never synced to iCloud Keychain or device backups.
    func testAccessibilityIsAfterFirstUnlockThisDeviceOnly() {
        XCTAssertEqual(
            attrs[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    // S6288's only remediation is a SecAccessControl requiring user presence, which would
    // break the silent background read. The item must therefore carry no access control.
    func testNoUserAuthenticationRequirement() {
        XCTAssertNil(attrs[kSecAttrAccessControl as String])
    }
}
