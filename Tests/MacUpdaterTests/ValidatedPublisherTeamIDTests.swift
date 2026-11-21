import Foundation
import Security
import Testing
import WegaTestSupport
@testable import WegaHelperKit

/// The publisher watchdog compared Team IDs that `teamID(ofAppAt:)` read straight out of the code
/// directory, without validating the signature. That value is only a claim. A bundle edited after
/// signing (a resource, `Info.plist`, a slice, a nested helper) still reports its publisher's Team
/// ID, and an ad-hoc signature can claim any Team ID. Both read back as the trusted publisher.
@Suite("Validated publisher Team ID")
struct ValidatedPublisherTeamIDTests {

    /// Red before the fix: the claim came back as the publisher.
    @Test func anAdHocSignatureClaimingATeamIDIsNotThatPublisher() async throws {
        let forged = try await ForgedSignatureBundle.make(claimingTeamID: "ABCDE12345")
        defer { forged.remove() }

        try #require(CodeSignatureVerifier.teamID(ofAppAt: forged.url) == "ABCDE12345",
                     "the fixture must claim the Team ID for the check below to mean anything")
        #expect(CodeSignatureVerifier.validatedTeamID(ofAppAt: forged.url) == nil,
                "no Apple-issued certificate carries the claimed Team ID")
    }

    /// The claim is interpolated into a code requirement. A quote in it would rewrite the
    /// requirement (`X" or anchor trusted or "Y`), so only the shape of a real Team ID gets that far.
    @Test func onlyTheShapeOfARealTeamIDReachesTheRequirement() {
        #expect(CodeSignatureVerifier.isWellFormedTeamID("ABCDE12345"))
        #expect(CodeSignatureVerifier.isWellFormedTeamID("2SB5Z68H26"))
        #expect(!CodeSignatureVerifier.isWellFormedTeamID("X\" or anchor trusted or \"Y"))
        #expect(!CodeSignatureVerifier.isWellFormedTeamID("abcde12345"))
        #expect(!CodeSignatureVerifier.isWellFormedTeamID("ABCDE1234"))
        #expect(!CodeSignatureVerifier.isWellFormedTeamID("ABCDE123456"))
        #expect(!CodeSignatureVerifier.isWellFormedTeamID("ABCDE1234\n"))
        #expect(!CodeSignatureVerifier.isWellFormedTeamID(""))
    }

    /// Any member of a team can make an Apple Development certificate in Xcode, and it carries the
    /// team's OU under an Apple anchor; only the account holder can make a Developer ID. So the
    /// requirement also demands the Developer ID intermediate (…6.2.6) and leaf (…6.1.13) markers,
    /// as the app and the helper already demand of each other.
    @Test func theRequirementDemandsADeveloperIDChainForTheClaimedTeam() throws {
        let requirement = CodeSignatureVerifier.developerIDRequirement(teamID: "ABCDE12345")

        #expect(requirement == "anchor apple generic "
            + "and certificate 1[field.1.2.840.113635.100.6.2.6] "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] "
            + "and certificate leaf[subject.OU] = \"ABCDE12345\"")
        var compiled: SecRequirement?
        #expect(SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess)
    }

    @Test func theValidatedReadChecksTheClaimAgainstTheDeveloperIDRequirement() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/WegaHelperKit/CodeSignatureVerifier.swift"),
            encoding: .utf8
        )
        let read = try #require(source.range(of: "public static func validatedTeamID(ofAppAt url: URL) -> String? {"))
        let body = source[read.upperBound...].prefix(400)

        #expect(body.contains("requirement: developerIDRequirement(teamID: claimed)"))
    }

    /// Measured on copies of real apps: the default check misses a flipped byte in the slice this
    /// Mac does not run, an edited script executable and a patched nested helper (Sparkle's
    /// `Autoupdate`). These three flags catch each of them, as `codesign --verify --deep --strict` does.
    /// Exactly these: a further one, such as `kSecCSConsiderExpiration`, would refuse genuine
    /// builds, and every baselined cask would then roll back as a publisher change.
    @Test func theValidatedReadChecksEveryArchitectureNestedCodeAndStrictly() {
        #expect(CodeSignatureVerifier.publisherValidationFlags == SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        ))
    }
}
