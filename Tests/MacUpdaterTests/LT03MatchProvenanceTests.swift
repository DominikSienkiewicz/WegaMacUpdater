import Foundation
import Testing
@testable import MacUpdaterCore

/// LT-03 (follow-up) — the match scorer has to be *told* how the match was found.
///
/// `LT-03` revived the Team ID branch of `CaskMatchScorer`, and recorded that two more of its
/// signals were still dead: `viaCustomMapping` and `caskNames` were hardcoded to `false` and
/// `[]` at both production call sites. The reason was structural rather than an oversight —
/// **how** a token was found is decided inside `CaskMatcher.match` and was then thrown away,
/// because `CaskMatch` carried nothing but the token. No caller could answer a question the
/// matcher had already answered and discarded.
///
/// That is not cosmetic. `MigrationAutoTakeover.decide` turns `.low` into `.blocked`, and every
/// entry in `MacUpdaterConstants.customCaskMappings` normalizes differently from its own token
/// — that is the entire reason the table exists. So the curated table, written precisely to
/// map apps whose name does not match their cask, scored `.low` and had its automatic takeover
/// refused. `REL-08` added that gate as a safety improvement and silently closed the six cases
/// the table was written for.
///
/// The fix carries provenance out of the matcher as part of `CaskMatch`, so the scorer takes a
/// fact instead of two parameters a caller cannot supply.
@Suite("LT-03 — match provenance reaches the scorer")
struct LT03MatchProvenanceTests {

    // MARK: The regression

    /// The bug, at the level a user meets it: an app in the curated table is offered for
    /// migration, and the takeover gate refuses it.
    ///
    /// Red before the fix: every one of these scored `.low`, so `decide` returned `.blocked`
    /// and the migration could not run at all.
    @Test(arguments: Array(MacUpdaterConstants.customCaskMappings))
    func everyCuratedMappingSurvivesTheTakeoverGate(mapping: (key: String, value: String)) {
        let match = CaskMatcher().match(
            applicationName: mapping.key,
            installedCasks: [],
            availableCasks: [BrewCask(token: mapping.value, name: [])]
        )

        #expect(match.provenance == .curatedMapping,
                "LT-03: \(mapping.key) → \(mapping.value) is in the curated table, and that is how it was matched")

        let confidence = CaskMatchScorer.score(provenance: match.provenance ?? .displayName)
        #expect(confidence == .high,
                "LT-03: a curated entry is a human's explicit statement that this app IS this cask")
        #expect(MigrationAutoTakeover.decide(confidence) != .blocked,
                """
                LT-03: \(mapping.key) → \(mapping.value) must not be blocked. The curated table \
                exists for apps whose name does not normalize to their token — blocking them \
                refuses exactly the cases it was written for.
                """)
    }

    /// The second dead signal. A match found through a cask's display name is plausible but
    /// not certain, so it asks for confirmation instead of being refused outright.
    ///
    /// Red before the fix: `caskNames: []` at both call sites made this branch unreachable, so
    /// it collapsed into `.low` → `.blocked` together with everything else.
    @Test func aDisplayNameMatchAsksForConfirmationRatherThanBeingRefused() throws {
        let match = CaskMatcher(customMappings: [:]).match(
            applicationName: "Docker Desktop",
            installedCasks: [],
            availableCasks: [BrewCask(token: "docker", name: ["Docker Desktop"])]
        )

        #expect(match == .candidate(token: "docker", provenance: .displayName))

        let confidence = CaskMatchScorer.score(provenance: try #require(match.provenance))
        #expect(confidence == .medium)
        #expect(MigrationAutoTakeover.decide(confidence) == .requiresConfirmation,
                "LT-03: a name match is plausible, so a human confirms it — it is not refused and not automatic")
    }

    // MARK: Provenance is the matcher's answer, not a guess

    /// Each way the matcher can arrive at a token reports itself distinctly. Without this the
    /// index cannot be asked *how* it hit: it merges tokens and display names into one lookup.
    @Test func eachRouteToATokenReportsItsOwnProvenance() {
        let matcher = CaskMatcher(customMappings: ["Legacy Name": "modern-token"])
        let casks = [BrewCask(token: "modern-token", name: ["Modern App"])]

        #expect(matcher.match(applicationName: "modern-token", installedCasks: ["modern-token"], availableCasks: casks)
            == .managed(token: "modern-token", provenance: .installedToken))
        #expect(matcher.match(applicationName: "Legacy Name", installedCasks: [], availableCasks: casks)
            == .candidate(token: "modern-token", provenance: .curatedMapping))
        #expect(matcher.match(applicationName: "Modern Token", installedCasks: [], availableCasks: casks)
            == .candidate(token: "modern-token", provenance: .token))
        #expect(matcher.match(applicationName: "Modern App", installedCasks: [], availableCasks: casks)
            == .candidate(token: "modern-token", provenance: .displayName))
        #expect(matcher.match(applicationName: "Nothing Like It", installedCasks: [], availableCasks: casks)
            == CaskMatch.none)
    }

    /// The curated table outranks the index. `Docker` is both a curated key and a normalized
    /// token in the catalog, and the two point at different casks — the human's entry wins,
    /// and says so.
    @Test func theCuratedTableOutranksAnIndexHitOnTheSameName() {
        let match = CaskMatcher(customMappings: ["Docker": "docker-desktop"]).match(
            applicationName: "Docker",
            installedCasks: [],
            availableCasks: [BrewCask(token: "docker", name: [])]
        )

        #expect(match == .candidate(token: "docker-desktop", provenance: .curatedMapping),
                "LT-03: the curated entry decides both the token and how the match is described")
    }

    // MARK: The scanner carries it forward

    /// Provenance is only useful if it survives the scan — the migration call sites read it
    /// off `ApplicationInfo`, never re-derive it.
    @Test func theScannedApplicationRemembersHowItWasMatched() {
        let info = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Docker.app"),
            name: "Docker",
            bundleIdentifier: "com.docker.docker",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false,
            caskToken: "docker-desktop",
            caskMatchProvenance: .curatedMapping
        )

        #expect(info.caskMatchProvenance == .curatedMapping)
        #expect(MigrationAutoTakeover.decide(CaskMatchScorer.score(provenance: .curatedMapping)) == .allowed)
    }

    /// An app that predates the field, or one matched by nothing at all, must not be talked up
    /// into a confident match by the absence of information.
    @Test func anUnknownProvenanceIsNeverTreatedAsAStrongSignal() {
        let info = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Mystery.app"),
            name: "Mystery",
            bundleIdentifier: nil,
            version: nil,
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false,
            caskToken: "mystery"
        )

        #expect(info.caskMatchProvenance == nil, "the field defaults to nothing known")
    }

    // MARK: Team ID still outranks everything

    /// LT-03's own signal keeps its precedence: a corroborated publisher decides the verdict
    /// whatever the provenance was, and a mismatch is still the hard veto that card chose.
    @Test func teamIDCorroborationStillOutranksProvenance() {
        #expect(CaskMatchScorer.score(provenance: .displayName,
                                      installedAppTeamID: "AAA", caskExpectedTeamID: "AAA") == .high,
                "LT-03: a corroborated publisher lifts a weaker route to certainty")
        #expect(CaskMatchScorer.score(provenance: .curatedMapping,
                                      installedAppTeamID: "AAA", caskExpectedTeamID: "BBB") == .low,
                "LT-03: a publisher mismatch overrules even a curated entry — the veto stays hard")
    }
}
