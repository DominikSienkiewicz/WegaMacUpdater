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

    /// Every test above proves a refusal. A regression that made the read return `nil` for genuine
    /// apps too would roll back every cask with a baseline as a publisher change while they all stay
    /// green, so one Developer ID app on this Mac must keep its Team ID. Up to three are tried, so
    /// one app that broke its own signature does not fail the test. Skipped where none is installed.
    @Test(.enabled(if: !InstalledDeveloperIDApps.candidates.isEmpty, "needs a Developer ID app in /Applications"))
    func aGenuineDeveloperIDAppKeepsItsTeamID() async {
        let candidates = Array(InstalledDeveloperIDApps.candidates.prefix(3))

        let validated = await offTheCooperativePool {
            candidates.map { CodeSignatureVerifier.validatedTeamID(ofAppAt: $0.url) }
        }

        #expect(zip(candidates, validated).contains { $0.teamID == $1 },
                "none of \(candidates.map(\.url.lastPathComponent)) kept its Team ID")
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

/// Developer ID apps in `/Applications`, fewest sealed files first so that validating them is
/// quick. Choosing them reads each signature's claim and leaf certificate and hashes nothing.
private enum InstalledDeveloperIDApps {
    struct Candidate: Sendable {
        let url: URL
        let teamID: String
        let sealSize: Int
    }

    static let candidates: [Candidate] = {
        let root = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let apps = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return apps
            .filter { $0.pathExtension == "app" }
            .compactMap(candidate(at:))
            .sorted { ($0.sealSize, $0.url.path) < ($1.sealSize, $1.url.path) }
    }()

    private static func candidate(at app: URL) -> Candidate? {
        guard let teamID = CodeSignatureVerifier.teamID(ofAppAt: app), leafIsDeveloperIDApplication(app) else {
            return nil
        }
        let seal = app.appendingPathComponent("Contents/_CodeSignature/CodeResources")
        guard let size = (try? seal.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return Candidate(url: app, teamID: teamID, sealSize: size)
    }

    private static func leafIsDeveloperIDApplication(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return false }
        return summary.hasPrefix("Developer ID Application:")
    }
}

/// Runs `work` on a thread of its own, so the cooperative pool is not blocked while it hashes.
private func offTheCooperativePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: work()) }.start()
    }
}
