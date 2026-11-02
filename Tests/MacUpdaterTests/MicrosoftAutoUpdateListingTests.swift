import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Microsoft AutoUpdate read-only listing")
struct MicrosoftAutoUpdateListingTests {
    @Test func capturedNoUpdatesTextIsRecognizedWithoutClaimingThisCopyIsCurrent() {
        let report = MicrosoftAutoUpdateReport.parse(result("\r\n\r\u{001B}[2K\rChecking for updates...\r\u{001B}[2K\rUpdate Assistant: Idle\r\u{001B}[2K\rUpdate Assistant: Checking\r\u{001B}[2K\rNo updates available\r\n\r\u{001B}[2K\rUpdate Assistant: Idle"))
        #expect(report.status == .noUpdatesReported)
        #expect(report.offers.isEmpty)
        #expect(report.check(app: office()) == .notApplicable)
    }

    @Test func publishedExplicitOfficeOfferPreservesVersionBuildAndApplicationIdentity() {
        // First-hand --list capture: https://github.com/pbowden-msft/msupdatehelper/issues/10
        let report = MicrosoftAutoUpdateReport.parse(result("""
            Checking for updates...
            Updates available:
            MSWD2019 Word Update 16.29.1 (19091700)
            XCEL2019 Excel Update 16.29.1 (19091700)
            """))
        #expect(report.status == .updatesReported)
        #expect(report.offers == [
            .init(applicationID: "MSWD2019", version: "16.29.1", build: "19091700"),
            .init(applicationID: "XCEL2019", version: "16.29.1", build: "19091700"),
        ])
        guard case .outdated(let item) = report.check(app: office()) else {
            Issue.record("An explicit Word offer newer than the local short version must produce an actionable row")
            return
        }
        #expect(item.path == office().path)
        #expect(item.bundleIdentifier == office().bundleIdentifier)
        #expect(item.availableVersion == "16.29.1 (19091700)")
        #expect(item.completionRequirement == .init(version: "16.29.1", field: .shortVersion, scheme: .buildNumbered))
    }

    @Test func matchingShortVersionDoesNotInferBuildOrPerCopyFreshness() {
        let report = MicrosoftAutoUpdateReport.parse(result("Updates available:\nMSWD2019 Word Update 16.29.1 (19091700)"))
        var app = office()
        app.version = "16.29.1"
        app.buildVersion = "unknown"
        #expect(report.check(app: app) == .notApplicable)
        app.version = nil
        #expect(report.check(app: app) == .notApplicable)
    }

    @Test(arguments: [
        "", "<plist><dict/></plist>", "Updates available:",
        "Updates available:\nMSWD2019 Word Update latest",
        "Updates available:\nMSWD2019 Excel Update 16.29.1 (19091700)",
        "Updates available:\nMSWD2019 Word Update 16.29.1 (19091700)\nMSWD2019 Word Update 16.30.0 (19100100)",
        "Updates available:\nMSWD2019 Word Update 16.29.1 (19091700)\nNo updates available",
        "No updates available\nUnknown diagnostic",
    ])
    func unknownOrContradictoryOutputCannotMeanCurrent(output: String) {
        let report = MicrosoftAutoUpdateReport.parse(result(output))
        #expect(report.status == .unrecognizedOutput)
        #expect(report.check(app: office()) == .failed)
    }

    @Test func processFailureOverridesAnyPartialOffer() {
        let report = MicrosoftAutoUpdateReport.parse(.init(exitCode: 1,
            stdout: "Updates available:\nMSWD2019 Word Update 16.29.1 (19091700)", stderr: "denied"))
        #expect(report.status == .failed)
        #expect(report.check(app: office()) == .failed)
    }

    @Test func knownAssistantFailureIsNotEmptySuccess() {
        let report = MicrosoftAutoUpdateReport.parse(result("No result returned from Update Assistant"))
        #expect(report.status == .failed)
    }

    @Test func masCopyNeverReceivesTheVendorOffer() {
        let report = MicrosoftAutoUpdateReport.parse(result("Updates available:\nMSWD2019 Word Update 16.29.1 (19091700)"))
        var app = office()
        app.isManagedByMas = true
        #expect(report.check(app: app) == .notApplicable)
    }

    @Test func missingUpdaterDoesNotRunAProcess() async {
        let runner = MicrosoftListingRunner(output: result("No updates available"))
        let report = await MicrosoftAutoUpdateClient(runner: runner,
            applicationURL: URL(fileURLWithPath: "/wega-test-fixtures/missing-MAU.app")).list()
        #expect(report.status == .notInstalled)
        #expect(await runner.requests.isEmpty)
    }

    @Test func discoveryChecksBundleIdentityAndUsesOnlyTheBoundedListCommand() async throws {
        let directory = try updaterFixture(bundleID: "com.microsoft.autoupdate2")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = MicrosoftListingRunner(output: result("No updates available"))
        let report = await MicrosoftAutoUpdateClient(runner: runner, applicationURL: directory).list()
        #expect(report.status == .noUpdatesReported)
        #expect(report.updaterVersion == "4.85")
        let requests = await runner.requests
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.executableURL == directory.appendingPathComponent("Contents/MacOS/msupdate"))
        #expect(request.arguments == ["--list", "--format", "plist"])
        #expect(request.timeout != nil)
        #expect(request.idleTimeout != nil)
    }

    @Test func foreignUpdaterBundleIsNotExecuted() async throws {
        let directory = try updaterFixture(bundleID: "com.example.fake")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = MicrosoftListingRunner(output: result("No updates available"))
        #expect(await MicrosoftAutoUpdateClient(runner: runner, applicationURL: directory).list().status == .failed)
        #expect(await runner.requests.isEmpty)
    }

    @Test func timeoutsRemainUnavailable() async throws {
        let directory = try updaterFixture(bundleID: "com.microsoft.autoupdate2")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = MicrosoftListingRunner(output: result(""), error: .timedOut(seconds: 60))
        #expect(await MicrosoftAutoUpdateClient(runner: runner, applicationURL: directory).list().status == .unavailable)
    }

    private func updaterFixture(bundleID: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let binary = directory.appendingPathComponent("Contents/MacOS/msupdate")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "4.85",
        ], format: .xml, options: 0).write(to: directory.appendingPathComponent("Contents/Info.plist"))
        return directory
    }

    private func office() -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/wega-test-fixtures/Word.app"), name: "Microsoft Word",
            bundleIdentifier: "com.microsoft.Word", version: "16.28", installDate: nil, updateDate: nil, isManagedByBrew: false)
    }

    private func result(_ output: String) -> ProcessResult { .init(exitCode: 0, stdout: output, stderr: "") }
}

private actor MicrosoftListingRunner: ProcessRunning {
    let output: ProcessResult
    let error: ProcessRunnerError?
    private(set) var requests: [ProcessRequest] = []

    init(output: ProcessResult, error: ProcessRunnerError? = nil) { self.output = output; self.error = error }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        if let error { throw error }
        return output
    }

    nonisolated func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
