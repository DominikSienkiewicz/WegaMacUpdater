import XCTest
@testable import MacUpdaterCore

/// Regression: the Homebrew cask `codex` installs only a CLI binary (no .app), yet
/// CaskMatcher matches the unrelated `/Applications/Codex.app` (Electron desktop app
/// with bundle id `com.openai.codex`) to that same token by normalized name.
///
/// Consequence in UpdateView: Codex.app was incorrectly flagged `isManagedByBrew = true`,
/// which gated out the Sparkle checker — so even with `SparkleFeedOverrides` in place
/// the appcast was never fetched and the update went unseen.
///
/// The fix is in UpdateView.scanManualUpdates (Sparkle now runs unconditionally,
/// priority dedup keeps cask > sparkle for the same path). This test pins the
/// misclassification so anyone touching CaskMatcher knows about it.
final class CaskMatcherCodexConflictTests: XCTestCase {
    func testCodexAppFalselyMatchesInstalledCodexCliCask() {
        let match = CaskMatcher(customMappings: [:]).match(
            applicationName: "Codex",
            installedCasks: ["codex"], // CLI binary cask
            availableCasks: []
        )
        XCTAssertEqual(match, .managed(token: "codex"))
    }
}
