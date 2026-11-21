import Foundation
import Testing
@testable import MacUpdaterCore

/// UXP-17 — the dropdown's rows lead to the update in the window, so each one carries the key
/// the window's inspector reads, its versions, and the same possible-security flag as the
/// window's badge.
@Suite("Menu bar entries")
struct MenuBarOutdatedEntriesTests {
    private func result() -> MenuBarScanResult {
        let brew = BrewOutdated(
            formulae: [],
            casks: [BrewOutdatedItem(name: "slack", installedVersions: ["4.47"], currentVersion: "4.48")]
        )
        let zed = ManualOutdatedApp(
            name: "Zed", path: URL(fileURLWithPath: "/Applications/Zed.app"),
            installedVersion: "0.150", availableVersion: "0.151", source: .sparkle,
            releaseNotes: ReleaseNotes(html: "<p>Fixes a security issue in the extension host.</p>", version: "0.151")
        )
        return MenuBarScanResult(brew: brew, mas: [], npm: [], manualApps: [zed],
                                 failedChecks: 0, scannedAt: Date(), total: 2)
    }

    @Test func entriesCarryTheWindowsKeysAndTheBadgesRules() {
        let result = result()
        let entries = result.outdatedEntries()
        #expect(entries.map(\.key) == ["c:slack", "m:/Applications/Zed.app"])
        #expect(entries.map(\.possibleSecurityFix) == [false, true])
        #expect(result.outdatedDisplayNames() == entries.map(\.name), "names still agree with the count")
        #expect(result.outdatedEntries(policies: ["c:slack": .ignored]).map(\.key) == ["m:/Applications/Zed.app"])
    }

    @Test func entriesCarryBothVersions() {
        let entries = result().outdatedEntries()
        #expect(entries.map(\.from) == ["4.47", "0.150"])
        #expect(entries.map(\.to) == ["4.48", "0.151"])
    }
}
