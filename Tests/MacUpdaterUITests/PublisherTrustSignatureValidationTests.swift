import Foundation
import MacUpdaterCore
import Testing
import WegaTestSupport

@testable import WegaMacUpdater

/// Where a Team ID becomes trust, the signature's claim is not enough. The check after an upgrade
/// and "Zaufaj nowemu podpisowi" read the validated Team ID, so a bundle that only claims a
/// publisher is not that publisher. Against a baseline the check after an upgrade rolls it back,
/// and trust is refused without asking. The check before an upgrade still reads the claim: an
/// installed app whose own signature broke must not block the update that replaces it.
@MainActor
@Suite("Publisher trust needs a valid signature")
struct PublisherTrustSignatureValidationTests {
    private final class PromptRecorder {
        var prompts: [ScanStore.PublisherChangePrompt] = []
    }

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Red before the fix: the user was asked to trust ABCDE12345, and on "yes" it replaced the baseline.
    @Test func aBundleThatOnlyClaimsTheNewTeamIDIsNeverOfferedForTrust() async throws {
        let forged = try await ForgedSignatureBundle.make(claimingTeamID: "ABCDE12345")
        defer { forged.remove() }
        let (defaults, teardown) = TestDefaults.isolated("publisher-trust-forged-signature")
        defer { teardown() }
        let teamIDs = TeamIDLedger(defaults: defaults)
        teamIDs.record(bundleID: TeamIDLedger.caskKey("forged"), teamID: "OLDTEAM123")
        let recorder = PromptRecorder()
        var dependencies = ScanStoreDependencies.live
        dependencies.teamIDLedger = teamIDs
        dependencies.rollbackLedger = CaskRollbackLedger(defaults: defaults)
        dependencies.confirmPublisherChange = { prompt in
            recorder.prompts.append(prompt)
            return true
        }
        let scan = ScanStore(dependencies: dependencies)

        await scan.trustNewPublisher(token: "forged", reportedTeamID: "ABCDE12345", appURL: forged.url)

        #expect(recorder.prompts.isEmpty, "a Team ID only the signature's claim names is never put to the user")
        #expect(teamIDs.teamID(forBundleID: TeamIDLedger.caskKey("forged")) == "OLDTEAM123")
        #expect(teamIDs.teamID(forBundleID: "com.example.forged") == nil)
        #expect(scan.banner?.variant == .danger)
    }

    /// Red before the fix: the claim read back as the installed publisher, so it matched a baseline
    /// of ABCDE12345 and the forged bundle passed as the same publisher.
    @Test func theCheckAfterAnUpgradeReadsNoPublisherFromAClaim() async throws {
        let forged = try await ForgedSignatureBundle.make(claimingTeamID: "ABCDE12345")
        defer { forged.remove() }

        #expect(await CaskRollbackGuard.Dependencies.live.teamIDAfterMutation(forged.url) == nil)
        #expect(CaskRollbackGuard.Dependencies.live.teamIDBeforeMutation(forged.url) == "ABCDE12345",
                "the check before an upgrade keeps reading the claim, so a broken installed app can still be updated")
    }

    /// The calls that pass no dependencies run their own reads, outside `Dependencies.live`.
    @Test func theCheckAfterAnUpgradeWithoutDependenciesReadsTheValidatedTeamIDToo() throws {
        let source = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Sources/MacUpdater/CaskRollbackGuard.swift"),
            encoding: .utf8
        )

        #expect(source.contains("CodeSignatureVerifier.validatedTeamID(ofAppAt: validationURL)"))
        #expect(!source.contains("CodeSignatureVerifier.teamID(ofAppAt: validationURL)"))
    }
}
