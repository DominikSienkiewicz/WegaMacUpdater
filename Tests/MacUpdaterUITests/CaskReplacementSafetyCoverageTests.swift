import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Cask replacement safety runtime coverage")
@MainActor
struct CaskReplacementSafetyCoverageTests {
    private let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
    private let userApplications = URL(fileURLWithPath: "/Users/tester/Applications", isDirectory: true)

    @Test func resolvedArtifactMustAlsoPassTheCanonicalPathResolver() async {
        let preparation = makePreparation(artifactName: "Acme.app")
        defer { cleanUp(preparation) }
        let expected = systemApplications.appendingPathComponent("Acme.app")
        let brew = brewService(json: caskJSON(artifacts: ["Acme.app"]))

        let resolved = await CaskReplacementSafety.resolveInstalledAppURL(
            preparation,
            brewService: brew,
            locationResolver: locationResolver(existing: [expected.path]),
            appPathResolver: appPathResolver(existing: [expected.path])
        )

        #expect(resolved == expected)
    }

    @Test func missingDuplicateAndAmbiguousArtifactsFailClosed() async {
        let preparation = makePreparation(artifactName: "Acme.app")
        defer { cleanUp(preparation) }
        let system = systemApplications.appendingPathComponent("Acme.app")
        let user = userApplications.appendingPathComponent("Acme.app")

        let missingIdentity = await CaskReplacementSafety.resolveInstalledAppURL(
            preparation,
            brewService: brewService(json: caskJSON(artifacts: ["Other.app"])),
            locationResolver: locationResolver(existing: []),
            appPathResolver: appPathResolver(existing: [])
        )
        let duplicateIdentity = await CaskReplacementSafety.resolveInstalledAppURL(
            preparation,
            brewService: brewService(json: caskJSON(artifacts: ["Acme.app", "Acme.app"])),
            locationResolver: locationResolver(existing: [system.path]),
            appPathResolver: appPathResolver(existing: [system.path])
        )
        let unresolved = await CaskReplacementSafety.resolveInstalledAppURL(
            preparation,
            brewService: brewService(json: caskJSON(artifacts: ["Acme.app"])),
            locationResolver: locationResolver(existing: []),
            appPathResolver: appPathResolver(existing: [])
        )
        let ambiguous = await CaskReplacementSafety.resolveInstalledAppURL(
            preparation,
            brewService: brewService(json: caskJSON(artifacts: ["Acme.app"])),
            locationResolver: locationResolver(existing: [system.path, user.path]),
            appPathResolver: appPathResolver(existing: [system.path])
        )

        #expect(missingIdentity == nil)
        #expect(duplicateIdentity == nil)
        #expect(unresolved == nil)
        #expect(ambiguous == nil)
    }

    @Test func canonicalPathDisagreementAndBrewFailureFailClosed() async {
        let preparation = makePreparation(artifactName: "Acme.app")
        defer { cleanUp(preparation) }
        let expected = systemApplications.appendingPathComponent("Acme.app")

        let disagreement = await CaskReplacementSafety.resolveInstalledAppURL(
            preparation,
            brewService: brewService(json: caskJSON(artifacts: ["Acme.app"])),
            locationResolver: locationResolver(existing: [expected.path]),
            appPathResolver: appPathResolver(existing: [])
        )
        let brewFailure = await CaskReplacementSafety.resolveInstalledAppURL(
            preparation,
            brewService: brewService(error: ReplacementStubError.failed),
            locationResolver: locationResolver(existing: [expected.path]),
            appPathResolver: appPathResolver(existing: [expected.path])
        )

        #expect(disagreement == nil)
        #expect(brewFailure == nil)
    }

    @Test func missingInstalledURLIsARollbackFailure() async {
        let preparation = makePreparation(artifactName: "Acme.app")
        defer { cleanUp(preparation) }

        let verdict = await CaskReplacementSafety.verify(preparation, installedAppURL: nil)

        #expect(verdict == .rollbackFailed)
    }

    private func makePreparation(artifactName: String) -> CaskReplacementSafety.Preparation {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-replacement-test-\(UUID().uuidString)", isDirectory: true)
        let operation = UpdateOperationStore(rootDirectory: root).begin(trigger: .adoption)
        let appURL = URL(fileURLWithPath: "/Original/\(artifactName)")
        return CaskReplacementSafety.Preparation(
            token: "acme",
            snapshotURL: root.appendingPathComponent("snapshot/\(artifactName)"),
            expectedTeamID: "TEAM",
            identity: CaskReplacementArtifactIdentity(bundleIdentifier: "com.example.acme", appURL: appURL),
            operation: operation
        )
    }

    private func brewService(json: String) -> BrewService {
        BrewService(
            locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
            runner: ReplacementRunner(result: .success(ProcessResult(exitCode: 0, stdout: json, stderr: "")))
        )
    }

    private func brewService(error: Error) -> BrewService {
        BrewService(
            locator: BinaryLocator(brewCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
            runner: ReplacementRunner(result: .failure(error))
        )
    }

    private func caskJSON(artifacts: [String]) -> String {
        let encoded = artifacts.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"casks\":[{\"token\":\"acme\",\"artifacts\":[{\"app\":[\(encoded)]}]}]}"
    }

    private func locationResolver(existing: Set<String>) -> CaskReplacementArtifactLocationResolver {
        CaskReplacementArtifactLocationResolver(
            applicationsDirectory: systemApplications,
            userApplicationsDirectory: userApplications,
            fileExists: { existing.contains($0.path) }
        )
    }

    private func appPathResolver(existing: Set<String>) -> CaskAppPathResolver {
        CaskAppPathResolver(
            applicationsDirectory: systemApplications,
            userApplicationsDirectory: userApplications,
            fileExists: { existing.contains($0.path) }
        )
    }

    private func cleanUp(_ preparation: CaskReplacementSafety.Preparation) {
        let root = preparation.snapshotURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ReplacementRunner: ProcessRunning, @unchecked Sendable {
    private let result: Result<ProcessResult, Error>

    init(result: Result<ProcessResult, Error>) {
        self.result = result
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try result.get()
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

private enum ReplacementStubError: Error {
    case failed
}
