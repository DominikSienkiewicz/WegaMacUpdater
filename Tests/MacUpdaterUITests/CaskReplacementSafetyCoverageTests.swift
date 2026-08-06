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

    // MARK: - Casks that install no .app at all

    /// `zoom` and `google-drive` are `pkg` casks: Homebrew's metadata declares no `app`
    /// artifact whatsoever. Adoption ran `brew install --cask --force` anyway, then asked
    /// `resolveInstalledAppURL` for an app artifact that cannot exist, got `nil`, and
    /// `verify` turned that `nil` into `.rollbackFailed` — "the new version failed its
    /// check and could not be restored". Nothing had been checked and nothing restored;
    /// the loudest verdict in the enum was reporting a resolution gap.
    ///
    /// The upgrade path already refuses these through `RollbackProtection`; adoption is
    /// the copy that forgot. Deciding it *before* brew runs also spares the user a
    /// pointless full reinstall of a current app.
    ///
    /// Red before the fix: no such gate existed.
    @Test func aCaskDeclaringNoAppArtifactIsRefusedBeforeBrewRuns() {
        let pkgOnly = CaskArtifactProfile(
            token: "zoom",
            artifacts: [CaskArtifact(kind: .pkg, names: ["zoomusInstallerFull.pkg"])]
        )

        #expect(CaskReplacementSafety.adoptionIsPointless(token: "zoom", profiles: [pkgOnly]),
                "a cask with only a pkg stanza can neither be snapshotted nor verified as an app")
    }

    /// The ordinary app cask (docker-desktop, and every cask adoption was built for)
    /// must keep passing the gate untouched.
    @Test func aCaskDeclaringAnAppArtifactStillProceeds() {
        let appCask = CaskArtifactProfile(
            token: "docker-desktop",
            artifacts: [CaskArtifact(kind: .app, names: ["Docker.app"]), CaskArtifact(kind: .binary)]
        )

        #expect(!CaskReplacementSafety.adoptionIsPointless(token: "docker-desktop", profiles: [appCask]))
    }

    /// The gate reads Homebrew metadata, which needs the network. When it is unavailable
    /// the answer is unknown, and an unknown must not become a refusal — behaviour then
    /// stays exactly as before, with the post-install resolution still failing closed.
    @Test func anUnknownProfileDoesNotBlockAdoption() {
        #expect(!CaskReplacementSafety.adoptionIsPointless(token: "zoom", profiles: []))
        #expect(!CaskReplacementSafety.adoptionIsPointless(
            token: "zoom",
            profiles: [CaskArtifactProfile(token: "something-else", artifacts: [CaskArtifact(kind: .app)])]
        ))
    }

    /// A gate nobody calls would pass every case above and still let the phantom banner
    /// through. Asserted at source level — the same technique REL-07 and REL-17 use —
    /// because driving the real `prepare()` needs brew, the keychain and a snapshot.
    @Test func prepareConsultsTheGateBeforeTakingASnapshot() throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdater/CaskReplacementSafety.swift"),
            encoding: .utf8
        )
        let gate = try #require(source.range(of: "adoptionIsPointless(token:"))
        let snapshot = try #require(source.range(of: "CaskRollbackGuard.snapshot("))

        #expect(gate.lowerBound < snapshot.lowerBound,
                "the refusal must come before the snapshot and before brew, not after the install")
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
