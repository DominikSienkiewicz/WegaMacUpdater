import Testing
import Foundation
@testable import MacUpdaterCore

/// The ignore/pin/skip policy design leans on reaching Wega's own row exactly like any other
/// app's, held today by construction and therefore one refactor away from being lost silently.
///
/// A second property — Wega's entry is counted as manual, never installable — used to have a
/// test here too, but that test only exercised `UnifiedUpdateCount`'s pass-through arithmetic
/// (feeding `unifiedCount(installable: 0, manual: 1)` literals and asserting they came back
/// unchanged) without ever constructing a `ManualOutdatedApp` with `source: .wega(...)`. It
/// could never turn red if a refactor actually moved Wega into the installable count. The real
/// installable/manual split is decided in the app target, by `ScanStore.updateCount`
/// (`Sources/MacUpdater/ScanStore.swift`), not in `MacUpdaterCore` — see
/// `SelfUpdateManualSplitTests` in `Tests/MacUpdaterUITests` for the test that actually reaches it.
@Suite("Self-update policy")
struct SelfUpdatePolicyTests {
    private func wega(version: String = "1.2.0") -> ManualOutdatedApp {
        ManualOutdatedApp(
            name: "Wega",
            path: URL(fileURLWithPath: "/Applications/WegaMacUpdater.app"),
            installedVersion: "1.0.0",
            availableVersion: version,
            source: .wega(releaseURL: URL(string: "https://example.com/release")!),
            origin: .manual,
            releaseNotes: "",
            bundleIdentifier: "com.wega.macupdater"
        )
    }

    /// The menu's "don't update this" reaches Wega's own row like any other app's.
    @Test func anIgnoreRuleSilencesTheWegaRow() {
        let app = wega()
        let filtered = UpdatePlanner.applyPolicies([app], policies: [app.policyKey: .ignored])
        #expect(filtered.isEmpty)
    }

    /// "Skip this version" is narrow on purpose — the next release surfaces again.
    @Test func skippingOneVersionDoesNotHideTheNextOne() {
        let skipped = wega(version: "1.2.0")
        let policies: [String: UpdatePolicy] = [skipped.policyKey: .skipped(version: "1.2.0")]

        #expect(UpdatePlanner.applyPolicies([skipped], policies: policies).isEmpty)
        #expect(UpdatePlanner.applyPolicies([wega(version: "1.3.0")], policies: policies).count == 1)
    }
}
