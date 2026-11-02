import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("LT-02 — incomplete ShipIt withdrawal cannot trigger an install on quit")
struct LT02ShipItWithdrawalFailureTests {
    @Test(arguments: [Failure.list, .inspection, .missingProgram, .removal])
    func aFailedWithdrawalLeavesTheSmokeInstanceRunning(_ failure: Failure) async {
        let runner = WithdrawalRunner(failure: failure)
        let handle = WithdrawalHandle()
        let probe = WithdrawalProbe(runner: runner, handle: handle)

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.discord, window: 0, terminationGrace: 0, probe: probe
        )

        #expect(verdict == .skipped(.selfUpdatePending))
        #expect(!LaunchSmokeTest.requiresRollback(verdict))
        #expect(handle.terminationRequests == 0, "An unverified withdrawal must never trigger ShipIt's install-on-quit")
        #expect(handle.forceTerminationRequests == 0)
        #expect(await !handle.hasExited())
    }

    @Test func successfulWithdrawalStillStopsOnlyTheSmokeInstance() async {
        let runner = WithdrawalRunner()
        let handle = WithdrawalHandle()
        let probe = WithdrawalProbe(runner: runner, handle: handle)

        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.discord, window: 0, terminationGrace: 0, probe: probe
        )

        #expect(verdict == .survived)
        #expect(runner.removedLabels == [WithdrawalRunner.discordLabel])
        #expect(handle.terminationRequests == 1)
        #expect(handle.forceTerminationRequests == 0)
    }

    @Test func anUnrelatedShipItJobIsNeverRemoved() async {
        let runner = WithdrawalRunner(ownsDiscordJob: false)
        let probe = WorkspaceAppLaunchProbe(runner: runner)

        let canTerminate = await probe.prepareForTermination(ofBundleAt: Self.discord)

        #expect(canTerminate)
        #expect(runner.removedLabels.isEmpty)
    }

    @Test func aCancelledTeardownStillInspectsAndWithdrawsBeforeQuitting() async {
        let runner = WithdrawalRunner()
        let probe = WorkspaceAppLaunchProbe(runner: runner)

        let canTerminate = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await probe.prepareForTermination(ofBundleAt: Self.discord)
        }.value

        #expect(canTerminate)
        #expect(runner.removedLabels == [WithdrawalRunner.discordLabel])
    }

    enum Failure: Sendable {
        case list
        case inspection
        case missingProgram
        case removal
    }

    private static let discord = URL(fileURLWithPath: "/Applications/Discord.app")
}

private final class WithdrawalRunner: ProcessRunning, @unchecked Sendable {
    static let discordLabel = "com.discord.discord.ShipIt"
    private let lock = NSLock()
    private let failure: LT02ShipItWithdrawalFailureTests.Failure?
    private let ownsDiscordJob: Bool
    private var removed: [String] = []
    var removedLabels: [String] { lock.withLock { removed } }

    init(failure: LT02ShipItWithdrawalFailureTests.Failure? = nil, ownsDiscordJob: Bool = true) {
        self.failure = failure
        self.ownsDiscordJob = ownsDiscordJob
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try Task.checkCancellation()
        switch request.arguments.first {
        case "list":
            if failure == .list { return Self.failed }
            return Self.success("-\t0\t\(Self.discordLabel)\n-\t0\tcom.example.other.ShipIt\n")
        case "print":
            let isDiscord = request.arguments.last?.hasSuffix("/\(Self.discordLabel)") == true
            if isDiscord, failure == .inspection { return Self.failed }
            if isDiscord, failure == .missingProgram { return Self.success("state = not running\n") }
            let app = isDiscord && ownsDiscordJob ? "Discord" : "Other"
            return Self.success("state = not running\nprogram = /Applications/\(app).app/Contents/Frameworks/Squirrel.framework/ShipIt\n")
        case "remove":
            if failure == .removal { return Self.failed }
            lock.withLock { removed.append(contentsOf: request.arguments.dropFirst()) }
            return Self.success("")
        default:
            return Self.failed
        }
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private static func success(_ output: String) -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: output, stderr: "")
    }

    private static var failed: ProcessResult {
        ProcessResult(exitCode: 1, stdout: "", stderr: "scripted launchctl failure")
    }
}

private struct WithdrawalProbe: AppLaunchProbing {
    let runner: WithdrawalRunner
    let handle: WithdrawalHandle

    func launch(bundleAt url: URL) async -> AppLaunchOutcome { .launched(handle) }

    func withdrawStagedSelfUpdate(ofBundleAt url: URL) async {
        await WorkspaceAppLaunchProbe(runner: runner).withdrawStagedSelfUpdate(ofBundleAt: url)
    }

    func prepareForTermination(ofBundleAt url: URL) async -> Bool {
        await WorkspaceAppLaunchProbe(runner: runner).prepareForTermination(ofBundleAt: url)
    }
}

private final class WithdrawalHandle: LaunchedAppHandle, @unchecked Sendable {
    let processIdentifier: Int32 = 4242
    private let lock = NSLock()
    private var exited = false
    private var politeRequests = 0
    private var forcedRequests = 0
    var terminationRequests: Int { lock.withLock { politeRequests } }
    var forceTerminationRequests: Int { lock.withLock { forcedRequests } }

    func hasExited() async -> Bool { lock.withLock { exited } }
    func requestTermination() async { lock.withLock { politeRequests += 1; exited = true } }
    func forceTerminate() async { lock.withLock { forcedRequests += 1; exited = true } }
}
