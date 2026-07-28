import Foundation
import Testing
@testable import MacUpdaterCore

/// LT-03 — the Team ID branch of `CaskMatchScorer` was reachable but never fed: both
/// publisher parameters defaulted to `nil` at every production call site, so the strongest
/// available signal never influenced a single decision. These tests pin the supply side
/// (`CaskPublisherCorrelator`) and the difference it makes to the takeover verdict.
@Suite("LT-03 publisher correlation in match scoring")
struct LT03PublisherCorrelationTests {
    private static let publisher = "T8RA8NEUTP"
    private static let impostor = "IMPOSTOR99"

    private func candidate(_ name: String, token: String?) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: "com.example.\(name)",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false,
            caskToken: token
        )
    }

    /// The regression this card exists for. "Figma" ↔ `figma` is an exact normalized token
    /// match, so on names alone it scores `.high` and `MigrationAutoTakeover` lets
    /// `brew install --cask --force figma` overwrite the bundle unattended — even when the
    /// installed copy is signed by a publisher the ledger has never associated with that
    /// cask. With the correlation supplied, the same match collapses to `.low` and the
    /// automatic takeover is refused.
    @Test func publisherMismatchBlocksATakeoverThatNamesAloneWouldAllow() {
        let correlator = CaskPublisherCorrelator(
            expectedTeamIDForCask: { $0 == "figma" ? Self.publisher : nil },
            installedTeamIDForApp: { _ in Self.impostor }
        )
        let correlation = correlator.correlate(
            caskToken: "figma",
            appPath: URL(fileURLWithPath: "/Applications/Figma.app")
        )
        #expect(correlation.isPublisherMismatch)

        // LT-03 (follow-up) — the scorer now takes how the match was found instead of loose
        // strings. An exact-token hit is the same signal this case always described.
        let namesOnly = CaskMatchScorer.score(provenance: .token)
        #expect(namesOnly == .high)
        #expect(MigrationAutoTakeover.decide(namesOnly) == .allowed,
                "baseline: without the publisher signal an exact-name match takes over unattended")

        let corroborated = CaskMatchScorer.score(
            provenance: .token,
            installedAppTeamID: correlation.installedAppTeamID,
            caskExpectedTeamID: correlation.caskExpectedTeamID
        )
        #expect(corroborated == .low)
        #expect(MigrationAutoTakeover.decide(corroborated) == .blocked,
                "LT-03: a publisher mismatch must veto the automatic takeover, whatever the names say")
    }

    /// The other direction: a match too fuzzy to trust by name is trustworthy once the
    /// installed bundle and the cask demonstrably share a publisher.
    @Test func matchingPublisherLiftsAFuzzyMatchOutOfTheBlockedBand() {
        let correlator = CaskPublisherCorrelator(
            expectedTeamIDForCask: { _ in Self.publisher },
            installedTeamIDForApp: { _ in Self.publisher }
        )
        let correlation = correlator.correlate(
            caskToken: "visual-studio-code",
            appPath: URL(fileURLWithPath: "/Applications/VS Code.app")
        )
        #expect(!correlation.isPublisherMismatch)

        // LT-03 (follow-up) — the original spelling of this case ("VS Code" scored against
        // token `visual-studio-code` and name "Visual Studio Code") is a state `CaskMatcher`
        // cannot produce: nothing there normalizes onto anything, so the matcher would return
        // `.none` and the app would never carry that token at all. The old scorer took loose
        // strings and let it be constructed. The weakest match the matcher *can* produce is a
        // display-name hit, and that is what stands in here — the assertion the case is about,
        // that a corroborated publisher raises the verdict, is unchanged.
        let namesOnly = CaskMatchScorer.score(provenance: .displayName)
        #expect(namesOnly == .medium)
        #expect(MigrationAutoTakeover.decide(namesOnly) == .requiresConfirmation)
        #expect(MigrationAutoTakeover.decide(CaskMatchScorer.unmatched) == .blocked,
                "an app the matcher tied to no cask is the case that stays blocked")

        let corroborated = CaskMatchScorer.score(
            provenance: .displayName,
            installedAppTeamID: correlation.installedAppTeamID,
            caskExpectedTeamID: correlation.caskExpectedTeamID
        )
        #expect(corroborated == .high)
        #expect(MigrationAutoTakeover.decide(corroborated) == .allowed)
    }

    /// ARCH-05b sibling, and the reason the ledger is consulted before the signature:
    /// activating this signal must not add a code-signature read per scanned application.
    /// A candidate whose cask has no recorded publisher has nothing to correlate against,
    /// so its bundle is never opened.
    @Test func signaturesAreReadOnlyForCandidatesWhoseCaskHasARecordedPublisher() {
        let reads = SignatureReadCounter()
        let correlator = CaskPublisherCorrelator(
            expectedTeamIDForCask: { $0 == "figma" ? Self.publisher : nil },
            installedTeamIDForApp: { _ in
                reads.record()
                return Self.publisher
            }
        )

        let figma = candidate("Figma", token: "figma")
        var applications = (0..<200).map { candidate("App\($0)", token: "token-\($0)") }
        applications.append(contentsOf: [candidate("Unmatched", token: nil), figma])

        let correlations = correlator.correlations(for: applications)

        #expect(reads.count == 1,
                "LT-03 must not turn a scan into one code-signature read per application")
        #expect(correlations.count == 1,
                "candidates with nothing to correlate must not occupy the map")
        #expect(correlations[figma.id]?.caskExpectedTeamID == Self.publisher)
        #expect(correlations[candidate("App0", token: "token-0").id] == nil)
    }

    /// A candidate Homebrew could not match at all never reaches either source.
    @Test func candidatesWithoutACaskTokenAreSkippedEntirely() {
        let correlator = CaskPublisherCorrelator(
            expectedTeamIDForCask: { _ in Self.publisher },
            installedTeamIDForApp: { _ in Self.publisher }
        )
        #expect(correlator.correlations(for: [candidate("Orphan", token: nil)]).isEmpty)
    }

    /// An empty recorded publisher is no publisher: the scorer would ignore it, so the
    /// signature read must not happen either.
    @Test func anEmptyRecordedPublisherCountsAsNoCorrelation() {
        let reads = SignatureReadCounter()
        let correlator = CaskPublisherCorrelator(
            expectedTeamIDForCask: { _ in "" },
            installedTeamIDForApp: { _ in
                reads.record()
                return Self.publisher
            }
        )
        let correlation = correlator.correlate(
            caskToken: "figma",
            appPath: URL(fileURLWithPath: "/Applications/Figma.app")
        )
        #expect(correlation == .unknown)
        #expect(reads.count == 0)
    }
}

/// Counts how often the injected signature reader ran — the assertion that keeps the
/// correlation cheap.
private final class SignatureReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }

    func record() {
        lock.lock(); defer { lock.unlock() }
        reads += 1
    }
}
