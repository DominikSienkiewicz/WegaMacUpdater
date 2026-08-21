import Testing
import Foundation
@testable import MacUpdaterCore

/// Which casks may be upgraded side by side.
///
/// A cask with a `pkg` / `installer` / `preflight` stanza can raise an admin-password
/// prompt, and two prompts on screen at once is not a thing a user can answer. Those run
/// one at a time; the rest share the pool.
@Suite("CaskUpgradeLanes")
struct CaskUpgradeLanesTests {

    private func profile(_ token: String, kinds: Set<CaskArtifactKind>) -> CaskArtifactProfile {
        CaskArtifactProfile(
            token: token,
            artifacts: kinds.map { CaskArtifact(kind: $0, names: ["\(token).thing"]) }
        )
    }

    @Test func appOnlyCasksShareThePool() {
        let lanes = CaskUpgradeLanes(
            tokens: ["figma", "slack"],
            profiles: [
                "figma": profile("figma", kinds: [.app]),
                "slack": profile("slack", kinds: [.app])
            ]
        )

        #expect(lanes.concurrent == ["figma", "slack"])
        #expect(lanes.serial.isEmpty)
    }

    @Test func aPasswordPromptingCaskIsSerialised() {
        let lanes = CaskUpgradeLanes(
            tokens: ["figma", "zoom"],
            profiles: [
                "figma": profile("figma", kinds: [.app]),
                "zoom": profile("zoom", kinds: [.pkg])
            ]
        )

        #expect(lanes.concurrent == ["figma"])
        #expect(lanes.serial == ["zoom"])
    }

    /// The map is only ever filled by a full scan: after `restoreLastScan()` it is empty.
    /// An unknown cask must not be assumed harmless — that is exactly the case that would
    /// put two Touch ID sheets on screen.
    @Test func anUnknownProfileIsTreatedAsPasswordPrompting() {
        let lanes = CaskUpgradeLanes(
            tokens: ["figma", "mystery"],
            profiles: ["figma": profile("figma", kinds: [.app])]
        )

        #expect(lanes.concurrent == ["figma"])
        #expect(lanes.serial == ["mystery"])
    }

    /// Every token given must come back exactly once: a cask silently dropped by the split
    /// is a cask the run never upgrades and never reports.
    @Test func theSplitLosesNothing() {
        let tokens = ["a", "b", "c", "d"]
        let lanes = CaskUpgradeLanes(
            tokens: tokens,
            profiles: [
                "a": profile("a", kinds: [.app]),
                "b": profile("b", kinds: [.installer]),
                "c": profile("c", kinds: [.app, .binary])
            ]
        )

        #expect(Set(lanes.concurrent + lanes.serial) == Set(tokens))
        #expect(lanes.concurrent.count + lanes.serial.count == tokens.count)
    }
}
