import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Mac App Store installed identity collection")
struct MasInstallationEvidenceServiceTests {
    private var record: InstallationCheck {
        let app = ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Renamed.app"), name: "Local name",
                                  bundleIdentifier: "com.example.store", version: "1.0",
                                  installDate: nil, updateDate: nil, isManagedByBrew: false, isManagedByMas: true)
        return InstallationCheck(app: app, sources: [], checkedAt: Date())
    }

    @Test func exactPathMetadataIsValidatedAgainstInstalledIDAndVersion() async throws {
        let runner = MasEvidenceRunner(listOutput: "123 Store name (1.0)", metadata: "123\0")
        let installation = record
        let evidence = try await service(runner).installationEvidence(for: [installation])
        #expect(evidence == [MasInstallationEvidence(installation: installation, appStoreID: "123")])
        let requests = await runner.requests
        #expect(requests.contains { $0.arguments == ["list"] })
        #expect(requests.contains { $0.executableURL.path == "/usr/bin/mdls"
            && $0.arguments == ["-raw", "-name", "kMDItemAppStoreAdamID", record.path.path] })
        #expect(requests.allSatisfy { $0.timeout != nil && $0.idleTimeout != nil })
    }

    @Test(arguments: ["", "(null)", "abc", "0", "123 456"])
    func missingOrAmbiguousMetadataDoesNotFallBackToName(_ metadata: String) async throws {
        let runner = MasEvidenceRunner(listOutput: "123 Local name (1.0)", metadata: metadata)
        #expect(try await service(runner).installationEvidence(for: [record]).isEmpty)
    }

    @Test(arguments: ["456 Local name (1.0)", "123 Local name (0.9)", "123 Local name ()", "123 One (1.0)\n123 Two (1.0)"])
    func missingDifferentVersionOrDuplicateInstalledIdentityIsUnknown(_ output: String) async throws {
        let runner = MasEvidenceRunner(listOutput: output, metadata: "123")
        #expect(try await service(runner).installationEvidence(for: [record]).isEmpty)
    }

    @Test func unavailableMetadataDoesNotConfirmCurrent() async throws {
        let runner = MasEvidenceRunner(listOutput: "123 Local name (1.0)", metadata: "123", metadataExit: 1)
        #expect(try await service(runner).installationEvidence(for: [record]).isEmpty)
    }

    @Test func anUnparseableSuccessfulOutdatedResponseIsNotAnEmptySuccess() async {
        let runner = MasEvidenceRunner(listOutput: "", metadata: "", outdatedOutput: "unrecognized response")
        await #expect(throws: (any Error).self) { try await service(runner).outdated() }
    }

    @Test func aSuccessfulOutdatedCommandWithDiagnosticOutputCannotConfirmCurrent() async {
        let runner = MasEvidenceRunner(listOutput: "", metadata: "", diagnostic: "Warning: lookup failed for 123")
        await #expect(throws: (any Error).self) { try await service(runner).outdated() }
    }

    private func service(_ runner: MasEvidenceRunner) -> MasService {
        MasService(locator: BinaryLocator(masCandidates: [URL(fileURLWithPath: "/usr/bin/true")]), runner: runner)
    }
}

private actor MasEvidenceRunner: ProcessRunning {
    let listOutput: String
    let metadata: String
    let metadataExit: Int32
    let outdatedOutput: String
    let diagnostic: String
    private(set) var requests: [ProcessRequest] = []

    init(listOutput: String, metadata: String, metadataExit: Int32 = 0, outdatedOutput: String = "", diagnostic: String = "") {
        self.listOutput = listOutput
        self.metadata = metadata
        self.metadataExit = metadataExit
        self.outdatedOutput = outdatedOutput
        self.diagnostic = diagnostic
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        if request.executableURL.lastPathComponent == "mdls" {
            return ProcessResult(exitCode: metadataExit, stdout: metadata, stderr: "")
        }
        return ProcessResult(exitCode: 0, stdout: request.arguments == ["list"] ? listOutput : outdatedOutput, stderr: diagnostic)
    }

    nonisolated func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
