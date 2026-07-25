import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Cask replacement artifact identity")
struct CaskReplacementArtifactIdentityTests {
    @Test func selectsTheSnapshottedArtifactInsteadOfTheFirstAppInTheCask() {
        let identity = CaskReplacementArtifactIdentity(
            bundleIdentifier: "com.example.second",
            appURL: URL(fileURLWithPath: "/Applications/Second.app")
        )
        let installationInfo = [BrewCaskInstallationInfo(
            token: "example-suite",
            appArtifacts: ["First.app", "Second.app"]
        )]

        #expect(identity.matchingArtifact(token: "example-suite", in: installationInfo) == "Second.app")
        #expect(identity.bundleIdentifier == "com.example.second")
        #expect(identity.artifactName == "Second.app")
    }

    @Test func missingOrAmbiguousArtifactFailsClosed() {
        let identity = CaskReplacementArtifactIdentity(
            bundleIdentifier: "com.example.second",
            appURL: URL(fileURLWithPath: "/Applications/Second.app")
        )

        #expect(identity.matchingArtifact(
            token: "example-suite",
            in: [BrewCaskInstallationInfo(
                token: "example-suite",
                appArtifacts: ["First.app"]
            )]
        ) == nil)
        #expect(identity.matchingArtifact(
            token: "example-suite",
            in: [BrewCaskInstallationInfo(
                token: "example-suite",
                appArtifacts: ["Second.app", "Nested/Second.app"]
            )]
        ) == nil)
    }

    @Test func replacementWiringUsesArtifactAndBundleIdentity() throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/CaskReplacementSafety.swift"),
            encoding: .utf8
        )

        #expect(source.contains("let identity: CaskReplacementArtifactIdentity"))
        #expect(source.contains("identity: CaskReplacementArtifactIdentity("))
        #expect(source.contains("preparation.identity.matchingArtifact("))
        #expect(source.contains("expectedBundleIdentifier: preparation.identity.bundleIdentifier"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
