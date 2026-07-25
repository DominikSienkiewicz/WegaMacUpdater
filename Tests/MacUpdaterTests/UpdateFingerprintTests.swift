import Testing
import Foundation
@testable import MacUpdaterCore

/// REL-02, path 6 — the background check deduplicated notifications by comparing the update
/// **count** with the count it last announced. One update installed and another one appearing
/// between two rounds leaves the count untouched, so the new update was never announced.
/// The watermark has to be the identity of the set, not its size.
@Suite("UpdateFingerprint")
struct UpdateFingerprintTests {

    private func item(_ name: String, kind: OutdatedItem.Kind = .cask) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: name, kind: kind), name: name,
                     from: "1.0", to: "2.0", kind: kind)
    }

    private func manual(_ path: String) -> ManualOutdatedApp {
        ManualOutdatedApp(name: URL(fileURLWithPath: path).lastPathComponent,
                          path: URL(fileURLWithPath: path),
                          installedVersion: "1.0", availableVersion: "2.0", source: .sparkle)
    }

    /// The regression itself: same count, different items.
    @Test func differentItemsWithTheSameCountDifferInFingerprint() {
        let before = UpdateFingerprint.of(items: [item("figma")], manual: [])
        let after  = UpdateFingerprint.of(items: [item("slack")], manual: [])

        #expect(before != after, "REL-02: a swapped update must not pass as 'nothing new'")
    }

    @Test func theSameSetHasTheSameFingerprintRegardlessOfOrder() {
        let one = UpdateFingerprint.of(items: [item("figma"), item("slack")], manual: [])
        let two = UpdateFingerprint.of(items: [item("slack"), item("figma")], manual: [])

        #expect(one == two)
    }

    /// A new item on top of the old ones is new, even though the old ones are unchanged.
    @Test func anAddedItemChangesTheFingerprint() {
        let before = UpdateFingerprint.of(items: [item("figma")], manual: [])
        let after  = UpdateFingerprint.of(items: [item("figma"), item("slack")], manual: [])

        #expect(before != after)
    }

    /// Two different sources can carry the same name — the source tag keeps them apart.
    @Test func theSameNameFromDifferentSourcesDiffers() {
        let cask    = UpdateFingerprint.of(items: [item("node", kind: .cask)], manual: [])
        let formula = UpdateFingerprint.of(items: [item("node", kind: .formula)], manual: [])

        #expect(cask != formula)
    }

    @Test func manualUpdatesParticipateInTheFingerprint() {
        let packagesOnly = UpdateFingerprint.of(items: [item("figma")], manual: [])
        let withManual   = UpdateFingerprint.of(items: [item("figma")], manual: [manual("/Applications/Zed.app")])

        #expect(packagesOnly != withManual)
    }

    @Test func nothingOutdatedHasTheEmptyFingerprint() {
        #expect(UpdateFingerprint.of(items: [], manual: []).isEmpty)
    }

    /// Persisted across launches, so it must not depend on a per-process hash seed.
    @Test func fingerprintIsStableForRepeatedInput() {
        let items = [item("figma"), item("wget", kind: .formula)]
        #expect(UpdateFingerprint.of(items: items, manual: []) == UpdateFingerprint.of(items: items, manual: []))
    }

    /// Ignored items are not announced, so they must not make the round look different.
    @Test func ignoredItemsAreExcluded() {
        let result = MenuBarScanResult(
            brew: BrewOutdated(formulae: [], casks: [BrewOutdatedItem(name: "figma",
                                                                     installedVersions: ["1.0"],
                                                                     currentVersion: "2.0")]),
            mas: [], npm: [], manualApps: [], failedChecks: 0, scannedAt: Date(), total: 1
        )
        let ignored = UpdateFingerprint.of(result: result,
                                           policies: [UpdatePlanner.key(name: "figma", kind: .cask): .ignored])

        #expect(ignored.isEmpty)
        #expect(UpdateFingerprint.of(result: result, policies: [:]) != ignored)
    }
}
