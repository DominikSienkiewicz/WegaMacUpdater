import Foundation
import Testing
@testable import MacUpdaterCore

/// LT-02 — the teardown must not hand the app's own updater the bundle Homebrew just wrote.
///
/// Observed with Discord on 2026-10-27, twice (16:23 and 17:51): the cask installed `0.0.420`,
/// the smoke test launched it hidden, and within the five-second window Discord's Squirrel
/// updater asked its own feed for an update. That feed lags the cask and offers its current build
/// to *any* other version, newer ones included, so it handed `0.0.420` the `0.0.419` build. Squirrel
/// staged it and started ShipIt (`com.discord.discord.ShipIt`), which waits for the app to quit.
/// The smoke test's polite quit was that moment: ShipIt swapped `/Applications/Discord.app` back
/// to a byte-identical `0.0.419` two seconds later, the verdict was already `.survived`, and the
/// update was reported as applied while Homebrew's Caskroom kept claiming `0.0.420`.
///
/// Squirrel's installer touches nothing while the app it updates is still running, so withdrawing
/// the staged install *before* the quit request is safe — and it is what Homebrew's own cask does
/// for Discord on uninstall (`launchctl remove com.discord.discord.ShipIt`).
@Suite("LT-02 — the teardown withdraws the app's staged self-update first")
struct LT02StagedSelfUpdateTests {

    @Test func aSurvivorsStagedSelfUpdateIsWithdrawnBeforeItIsAskedToQuit() async {
        // Given an instance that survives the window and quits when asked
        let journal = TeardownJournal()
        let probe = TeardownRecordingProbe(journal: journal, diesOnItsOwn: false)

        // When the smoke test tears it down
        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.1, pollInterval: 0.02, terminationGrace: 0.2, probe: probe
        )

        // Then the app's staged install is withdrawn while it still runs, and only then is it quit
        #expect(verdict == .survived)
        #expect(Array(journal.events.prefix(2)) == [.withdrewStagedSelfUpdate(Self.bundle), .askedToQuit],
                "LT-02: a quit before the withdrawal is the moment ShipIt swaps the bundle back")
    }

    /// ShipIt swaps the bundle only after the app is gone, and takes seconds to do it — Discord's
    /// started 0.4 s after the quit and finished 2 s later. Whatever reads the bundle next (the
    /// guard's version check, a snapshot restore) must not run inside that swap.
    @Test func theTeardownWaitsForTheAppsUpdaterOnceTheInstanceIsGone() async {
        // Given an instance that survives the window and quits when asked
        let journal = TeardownJournal()
        let probe = TeardownRecordingProbe(journal: journal, diesOnItsOwn: false)

        // When the smoke test tears it down
        _ = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.1, pollInterval: 0.02, terminationGrace: 0.2, probe: probe
        )

        // Then the verdict is only handed back after the app's updater has had its turn
        #expect(journal.events.last == .awaitedSelfUpdate(Self.bundle))
    }

    @Test func anInstanceThatDiedOnItsOwnIsNotTouchedButItsUpdaterIsAwaited() async {
        // Given an instance that exits inside the window
        let journal = TeardownJournal()
        let probe = TeardownRecordingProbe(journal: journal, diesOnItsOwn: true)

        // When the smoke test reports it
        let verdict = await LaunchSmokeTest.run(
            bundleAt: Self.bundle, window: 0.2, pollInterval: 0.02, terminationGrace: 0.2, probe: probe
        )

        // Then nothing of the app's own is withdrawn or quit — but the rollback that follows must
        // not restore the snapshot while a ShipIt woken by that exit is still swapping the bundle
        guard case .exitedEarly = verdict else {
            Issue.record("expected .exitedEarly, got \(verdict)")
            return
        }
        #expect(journal.events == [.awaitedSelfUpdate(Self.bundle)])
    }

    private static let bundle = URL(fileURLWithPath: "/Applications/Discord.app")
}

// MARK: - Squirrel's ShipIt job, as launchctl describes it

@Suite("LT-02 — finding the ShipIt job that belongs to a bundle")
struct SquirrelShipItJobTests {

    @Test func onlyShipItLabelsAreCandidates() {
        let list = """
        PID\tStatus\tLabel
        -\t0\tcom.microsoft.VSCode.ShipIt
        -\t0\tcom.discord.discord.ShipIt
        412\t0\tcom.apple.Finder
        -\t0\tcom.example.ShipItNot
        """
        #expect(SquirrelShipItJob.candidateLabels(inLaunchctlList: list)
                == ["com.microsoft.VSCode.ShipIt", "com.discord.discord.ShipIt"])
    }

    @Test func theJobsProgramIsReadFromLaunchctlPrint() {
        // Trimmed from `launchctl print gui/501/com.discord.discord.ShipIt` on 2026-10-29.
        let printed = """
        gui/501/com.discord.discord.ShipIt = {
        \tactive count = 0
        \tpath = (submitted by Discord[35548])
        \ttype = Submitted
        \tstate = not running
        \tprogram = /Applications/Discord.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt
        \targuments = {
        \t\t/Applications/Discord.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt
        \t\tcom.discord.discord.ShipIt
        \t}
        }
        """
        #expect(SquirrelShipItJob.programPath(inLaunchctlPrint: printed)
                == "/Applications/Discord.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt")
    }

    @Test func aJobBelongsToTheBundleItsProgramLivesIn() {
        let discord = URL(fileURLWithPath: "/Applications/Discord.app")
        let ship = "/Applications/Discord.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt"

        #expect(SquirrelShipItJob.program(ship, belongsTo: discord))
        #expect(SquirrelShipItJob.program(
            "/Applications/Visual Studio Code.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt",
            belongsTo: discord
        ) == false)
        #expect(SquirrelShipItJob.program(
            "/Applications/Discord.app Helper/Contents/ShipIt", belongsTo: discord
        ) == false, "a sibling whose name merely starts with the bundle's is not inside it")
    }

    @Test func aJobIsRunningOnlyWhenLaunchctlSaysSo() {
        #expect(SquirrelShipItJob.isRunning(inLaunchctlPrint: "gui/501/x = {\n\tstate = running\n}"))
        #expect(SquirrelShipItJob.isRunning(inLaunchctlPrint: "gui/501/x = {\n\tstate = not running\n}") == false)
    }

    @Test func waitingForTheUpdaterEndsOnceItsJobStopsRunning() async {
        // Given Discord's ShipIt mid-install for two more polls
        let runner = ScriptedLaunchctl(states: ["running", "running", "not running"])

        // When the teardown waits for it
        await SquirrelShipItJob.waitUntilFinished(forBundleAt: Self.discord, runner: runner,
                                                  timeout: 5, pollInterval: 0.01)

        // Then it returned only after launchctl reported the job stopped
        #expect(runner.printsServed == 3)
    }

    private static let discord = URL(fileURLWithPath: "/Applications/Discord.app")
}

/// `launchctl`, scripted: one Discord ShipIt job whose `state` follows `states`, one poll at a time.
private final class ScriptedLaunchctl: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String]
    private var removedLabels: [String] = []
    private var prints = 0

    init(states: [String]) { self.states = states }

    var removed: [String] { lock.withLock { removedLabels } }
    var printsServed: Int { lock.withLock { prints } }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try Task.checkCancellation()
        switch request.arguments.first {
        case "list":
            return ProcessResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n-\t0\tcom.discord.discord.ShipIt\n", stderr: "")
        case "print":
            let state: String = lock.withLock {
                prints += 1
                return states.count > 1 ? states.removeFirst() : states[0]
            }
            let program = "/Applications/Discord.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt"
            return ProcessResult(exitCode: 0, stdout: "\tstate = \(state)\n\tprogram = \(program)\n", stderr: "")
        case "remove":
            lock.withLock { removedLabels.append(contentsOf: request.arguments.dropFirst()) }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        default:
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

// MARK: - Stand-ins

private enum TeardownEvent: Equatable {
    case withdrewStagedSelfUpdate(URL)
    case askedToQuit
    case awaitedSelfUpdate(URL)
}

private final class TeardownJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TeardownEvent] = []

    var events: [TeardownEvent] { lock.withLock { recorded } }

    func record(_ event: TeardownEvent) {
        lock.withLock { recorded.append(event) }
    }
}

private final class TeardownRecordingProbe: AppLaunchProbing, @unchecked Sendable {
    private let journal: TeardownJournal
    private let diesOnItsOwn: Bool

    init(journal: TeardownJournal, diesOnItsOwn: Bool) {
        self.journal = journal
        self.diesOnItsOwn = diesOnItsOwn
    }

    func launch(bundleAt url: URL) async -> AppLaunchOutcome {
        .launched(TeardownRecordingHandle(journal: journal, diesOnItsOwn: diesOnItsOwn))
    }

    func withdrawStagedSelfUpdate(ofBundleAt url: URL) async {
        journal.record(.withdrewStagedSelfUpdate(url))
    }

    func waitForSelfUpdate(ofBundleAt url: URL) async {
        journal.record(.awaitedSelfUpdate(url))
    }
}

private final class TeardownRecordingHandle: LaunchedAppHandle, @unchecked Sendable {
    let processIdentifier: Int32 = 4242

    private let journal: TeardownJournal
    private let lock = NSLock()
    private var exited: Bool

    init(journal: TeardownJournal, diesOnItsOwn: Bool) {
        self.journal = journal
        self.exited = diesOnItsOwn
    }

    func hasExited() async -> Bool { lock.withLock { exited } }

    func requestTermination() async {
        journal.record(.askedToQuit)
        lock.withLock { exited = true }
    }

    func forceTerminate() async {
        lock.withLock { exited = true }
    }
}
