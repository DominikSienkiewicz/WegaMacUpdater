import Foundation
import Testing

/// Regression coverage for replacement flows that move an app or establish a cask-key
/// publisher baseline only after the original bundle has already been overwritten.
@Suite("Cask replacement identity regression")
struct CaskReplacementIdentityRegressionTests {
    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func section(_ source: String, from start: String, to end: String) throws -> Substring {
        let startRange = try #require(source.range(of: start))
        let tail = source[startRange.lowerBound...]
        let endRange = try #require(tail.range(of: end))
        return tail[..<endRange.lowerBound]
    }

    @Test func replacementCarriesThePremutationPublisherIntoDirectVerification() throws {
        let safety = try source("Sources/MacUpdater/CaskReplacementSafety.swift")
        let guardSource = try source("Sources/MacUpdater/CaskRollbackGuard.swift")

        #expect(safety.contains("let expectedTeamID: String?"))
        #expect(safety.contains("expectedTeamID: installedTeamID"))
        #expect(safety.contains("CaskRollbackGuard.verify("))
        #expect(safety.contains("expectedTeamID: preparation.expectedTeamID"))
        #expect(guardSource.contains("snapshotURL: URL"))
        #expect(guardSource.contains("validationURL: URL"))
        #expect(guardSource.contains("case expected(String?)"))
        #expect(guardSource.contains("expectedTeamID == installedTeamID"))
    }

    @Test func replacementCallersResolveTheInstalledArtifactAfterBrewMutation() throws {
        let actions = try ScanStoreSources.everything()
        let manual = try section(
            actions,
            from: "func installManual(token: String) async",
            to: "private func reportManualReplacementVerification("
        )
        let migrationSource = try source("Sources/MacUpdater/MigrationView.swift")
        let migration = try section(
            migrationSource,
            from: "private func performMigration(_ app: ApplicationInfo, token: String) async",
            to: "private func reportMigrationVerification("
        )

        let manualMutation = try #require(manual.range(of: "model.brewService.events(arguments: installArgs)"))
        let manualResolution = try #require(manual.range(of: "CaskReplacementSafety.resolveInstalledAppURL("))
        let manualVerification = try #require(manual.range(of: "installedAppURL: installedAppURL"))
        #expect(manualMutation.lowerBound < manualResolution.lowerBound)
        #expect(manualResolution.lowerBound < manualVerification.lowerBound)

        let migrationMutation = try #require(migration.range(of: "model.brewService.events(arguments:"))
        let migrationResolution = try #require(migration.range(of: "CaskReplacementSafety.resolveInstalledAppURL("))
        let migrationVerification = try #require(migration.range(of: "installedAppURL: installedAppURL"))
        #expect(migrationMutation.lowerBound < migrationResolution.lowerBound)
        #expect(migrationResolution.lowerBound < migrationVerification.lowerBound)
    }

    @Test func unresolvedPostInstallPathFailsClosedWithoutFallingBackToTheOldPath() throws {
        let safety = try source("Sources/MacUpdater/CaskReplacementSafety.swift")
        let resolver = try section(
            safety,
            from: "static func resolveInstalledAppURL(",
            to: "static func verify("
        )
        let verificationStart = try #require(safety.range(of: "static func verify("))
        let verification = safety[verificationStart.lowerBound...]

        #expect(resolver.contains("brewService.caskInstallationInfo(tokens: [token])"))
        #expect(resolver.contains("CaskAppPathResolver().appPaths(from: installationInfo)[token]"))
        #expect(verification.contains("guard let installedAppURL else { return .rollbackFailed }"))
        #expect(!verification.contains("preparation.appURL"))
    }

}
