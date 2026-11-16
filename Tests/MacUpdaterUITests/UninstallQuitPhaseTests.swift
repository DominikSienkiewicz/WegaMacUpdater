import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

/// A fake process table the injected seams read and mutate.
private final class ProcessTable: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [RunningApplicationTarget] = []
    private var log: [String] = []
    private var waits = 0
    private var reads = 0
    var onWait: @Sendable (ProcessTable, Int) -> Void = { _, _ in }
    var onQuit: @Sendable (ProcessTable, RunningApplicationTarget) -> Bool = { _, _ in false }
    var killSucceeds = true

    var processes: [RunningApplicationTarget] {
        get { lock.withLock { table } }
        set { lock.withLock { table = newValue } }
    }
    var events: [String] { lock.withLock { log } }
    var waitCount: Int { lock.withLock { waits } }
    var readCount: Int { lock.withLock { reads } }

    func remove(pid: Int32) {
        lock.withLock { table.removeAll { $0.processIdentifier == pid } }
    }

    func recordRead() -> [RunningApplicationTarget] {
        lock.withLock { reads += 1; return table }
    }

    func recordQuit(_ target: RunningApplicationTarget) {
        lock.withLock { log.append("quit \(target.processIdentifier)") }
    }

    func recordKill(_ pid: Int32) {
        lock.withLock { log.append("kill \(pid)") }
    }

    func recordWait() -> Int {
        lock.withLock { waits += 1; log.append("wait"); return waits }
    }

    var dependencies: UninstallCoordinator.Dependencies {
        UninstallCoordinator.Dependencies(
            uninstallCask: { _, _, _ in },
            trashItem: { _ in },
            trashLeftovers: { LeftoverCleanup.Result(removed: $0) },
            protection: { _ in nil },
            runningApplications: { self.recordRead() },
            requestQuit: { target in
                self.recordQuit(target)
                return self.onQuit(self, target)
            },
            forceKill: { pid in
                self.recordKill(pid)
                guard self.killSucceeds else { return false }
                self.remove(pid: pid)
                return true
            },
            waitBetweenRunningChecks: { self.onWait(self, self.recordWait()) }
        )
    }
}

@MainActor
@Suite("Uninstall quit phase")
struct UninstallQuitPhaseTests {
    private func app(_ name: String, brew: Bool = false) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: "com.example.\(name.lowercased())",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: brew,
            caskToken: brew ? name.lowercased() : nil
        )
    }

    private func process(_ app: ApplicationInfo, pid: Int32) -> RunningApplicationTarget {
        RunningApplicationTarget(
            processIdentifier: pid,
            bundleURL: app.path,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            processName: app.name
        )
    }

    @Test func quitRequestsGoOutBeforeAnyWait() async {
        let alpha = app("Alpha"), bravo = app("Bravo")
        let table = ProcessTable()
        table.processes = [process(alpha, pid: 10), process(bravo, pid: 20)]
        table.onWait = { table, _ in table.processes = [] }
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)

        let result = await coordinator.requestQuit([alpha, bravo])

        #expect(table.events == ["quit 10", "quit 20", "wait"])
        #expect(result.stopped == [alpha.id, bravo.id])
    }

    @Test func gracefulStopEndsInStopped() async {
        let alpha = app("Alpha")
        let table = ProcessTable()
        table.processes = [process(alpha, pid: 10)]
        table.onQuit = { table, target in table.remove(pid: target.processIdentifier); return true }
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)

        let result = await coordinator.requestQuit([alpha])

        #expect(result == UninstallQuitResult(stopped: [alpha.id], stillRunning: [], ambiguous: []))
        #expect(table.waitCount == 0)
    }

    @Test func notRunningTargetIsStoppedWithoutAQuitRequest() async {
        let alpha = app("Alpha")
        let table = ProcessTable()
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)

        let result = await coordinator.requestQuit([alpha])

        #expect(result.stopped == [alpha.id])
        #expect(table.events.isEmpty)
    }

    @Test func stubbornAppEndsInStillRunning() async {
        let alpha = app("Alpha")
        let table = ProcessTable()
        table.processes = [process(alpha, pid: 10)]
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)

        let result = await coordinator.requestQuit([alpha])

        #expect(result.stillRunning == [alpha])
        #expect(result.stopped.isEmpty)
        #expect(table.readCount == 11)  // one resolve before the quit requests, then ten rounds
        #expect(table.waitCount == 9)
    }

    @Test func aRefusedQuitRequestIsStillPolledAndCanStop() async {
        let alpha = app("Alpha")
        let table = ProcessTable()
        table.processes = [process(alpha, pid: 10)]
        table.onWait = { table, count in if count == 3 { table.processes = [] } }
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)

        let result = await coordinator.requestQuit([alpha])

        #expect(result.stopped == [alpha.id])
        #expect(table.waitCount == 3)
    }

    @Test func ambiguousTargetIsNeverAskedToQuit() async {
        let alpha = app("Alpha")
        let table = ProcessTable()
        table.processes = [process(alpha, pid: 10), process(alpha, pid: 11)]
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)

        let quit = await coordinator.requestQuit([alpha])
        let forced = await coordinator.forceQuit([alpha])

        #expect(quit.ambiguous == [alpha.id])
        #expect(forced.ambiguous == [alpha.id])
        #expect(table.events.isEmpty)
    }

    @Test func aTargetThatBecomesAmbiguousWhilePollingMovesToAmbiguous() async {
        let alpha = app("Alpha")
        let table = ProcessTable()
        table.processes = [process(alpha, pid: 10)]
        table.onWait = { table, _ in table.processes.append(table.processes[0].withPID(11)) }
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)

        let result = await coordinator.requestQuit([alpha])

        #expect(result.ambiguous == [alpha.id])
        #expect(result.stillRunning.isEmpty)
        #expect(!table.events.contains { $0.hasPrefix("kill") })
    }

    @Test func brewTargetIsAlsoAskedToQuit() async {
        let cask = app("Charlie", brew: true)
        let table = ProcessTable()
        table.processes = [process(cask, pid: 30)]
        table.onQuit = { table, target in table.remove(pid: target.processIdentifier); return true }
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)

        let result = await coordinator.requestQuit([cask])

        #expect(table.events == ["quit 30"])
        #expect(result.stopped == [cask.id])
    }

    @Test func otherCopyOfTheAppIsNeverTouched() async {
        let alpha = app("Alpha")
        let otherCopy = ApplicationInfo(
            path: URL(fileURLWithPath: "/Users/me/Alpha.app"),
            name: "Alpha",
            bundleIdentifier: alpha.bundleIdentifier,
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )
        let table = ProcessTable()
        table.processes = [process(otherCopy, pid: 99)]
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)

        let quit = await coordinator.requestQuit([alpha])
        let forced = await coordinator.forceQuit([alpha])

        #expect(quit.stopped == [alpha.id])
        #expect(forced.stopped == [alpha.id])
        #expect(table.events.isEmpty)
    }

    @Test func forceQuitKillsTheReResolvedPID() async {
        let alpha = app("Alpha")
        let table = ProcessTable()
        table.processes = [process(alpha, pid: 10)]
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)
        _ = await coordinator.requestQuit([alpha])
        table.processes = [process(alpha, pid: 200)]

        let result = await coordinator.forceQuit([alpha])

        #expect(table.events.filter { $0.hasPrefix("kill") } == ["kill 200"])
        #expect(result.stopped == [alpha.id])
    }

    @Test func forceQuitOfAnAppThatAlreadyQuitKillsNothing() async {
        let alpha = app("Alpha")
        let table = ProcessTable()
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)

        let result = await coordinator.forceQuit([alpha])

        #expect(result.stopped == [alpha.id])
        #expect(table.events.isEmpty)
    }

    @Test func forceQuitDoesNotSendNewQuitRequests() async {
        let alpha = app("Alpha")
        let table = ProcessTable()
        table.processes = [process(alpha, pid: 10)]
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)

        _ = await coordinator.forceQuit([alpha])

        #expect(table.events == ["kill 10"])
    }

    @Test func forceKillFailureStaysStillRunning() async {
        let alpha = app("Alpha")
        let table = ProcessTable()
        table.processes = [process(alpha, pid: 10)]
        table.killSucceeds = false
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)

        let result = await coordinator.forceQuit([alpha])

        #expect(result.stillRunning == [alpha])
        #expect(result.stopped.isEmpty)
    }

    @Test func forceKilledProcessThatLingersStaysStillRunning() async {
        let alpha = app("Alpha")
        let table = ProcessTable()
        table.processes = [process(alpha, pid: 10)]
        var dependencies = table.dependencies
        dependencies.forceKill = { pid in table.recordKill(pid); return true }
        let coordinator = UninstallCoordinator(dependencies: dependencies)

        let result = await coordinator.forceQuit([alpha])

        #expect(result.stillRunning == [alpha])
    }

    @Test func runningStatesReportEachTarget() {
        let alpha = app("Alpha"), bravo = app("Bravo")
        let table = ProcessTable()
        table.processes = [process(alpha, pid: 10)]
        let coordinator = UninstallCoordinator(dependencies: table.dependencies)

        let states = coordinator.runningStates(for: [alpha, bravo])

        #expect(states[alpha.id] == .running(process(alpha, pid: 10)))
        #expect(states[bravo.id] == .notRunning)
    }
}

private extension RunningApplicationTarget {
    func withPID(_ pid: Int32) -> RunningApplicationTarget {
        RunningApplicationTarget(
            processIdentifier: pid,
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            processName: processName
        )
    }
}
