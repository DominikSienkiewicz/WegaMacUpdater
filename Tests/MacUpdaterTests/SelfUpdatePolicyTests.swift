import Testing
import Foundation
@testable import MacUpdaterCore

/// Two properties the self-update design leans on, held today by construction and therefore
/// one refactor away from being lost silently.
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

    /// "Update all" must never try to replace the app that is running the update: Wega's entry
    /// is manual, and the button counts only the installable half.
    @Test func theWegaEntryIsCountedAsManualNotInstallable() {
        let count = UpdatePlanner.unifiedCount(installable: 0, manual: 1)
        #expect(count.installable == 0)
        #expect(count.manual == 1)
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
