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
