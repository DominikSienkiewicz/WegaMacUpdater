import Foundation
import Testing
@testable import WegaHelperKit

/// R2-4 (Aneks E.4, E.7): the root helper exits once nothing needs it, and never while a connection is
/// open or work is running. Time belongs to the fake scheduler: a test lets a minute pass by running
/// the checks the monitor scheduled, so no test waits on the wall clock.
@Suite("Helper idle monitor")
struct HelperIdleMonitorTests {

    @Test func withNothingToDoTheHelperExitsAMinuteAfterItStarts() {
        let fixture = Fixture()
        #expect(fixture.scheduler.delays.isEmpty, "nothing is armed before start()")

        fixture.monitor.start()
        #expect(fixture.scheduler.delays == [.seconds(60)])
        fixture.scheduler.runPending()

        #expect(fixture.exits.count == 1)
    }

    @Test func anOpenConnectionKeepsTheHelperAliveAndItsEndStartsAFreshMinute() {
        let fixture = Fixture()
        fixture.monitor.start()
        let connection = fixture.monitor.begin()

        fixture.scheduler.runPending()
        #expect(fixture.exits.count == 0, "a connection is open")
        #expect(fixture.scheduler.delays.isEmpty, "nothing is armed while a connection is open")

        connection.end()
        #expect(fixture.scheduler.delays == [.seconds(60)])
        fixture.scheduler.runPending()
        #expect(fixture.exits.count == 1)
    }

    /// The check armed at start comes due less than a minute after the last connection closed; the
    /// generation tells it that something happened in between.
    @Test func activityDuringTheCountdownCancelsIt() {
        let fixture = Fixture()
        fixture.monitor.start()
        fixture.monitor.begin().end()
        #expect(fixture.scheduler.delays == [.seconds(60), .seconds(60)])

        fixture.scheduler.runOldest()
        #expect(fixture.exits.count == 0, "the helper was idle for less than a minute")

        fixture.scheduler.runOldest()
        #expect(fixture.exits.count == 1)
    }

    /// H25: an invalidation handler that fires twice must not count the connection's end twice.
    @Test func endingOneActivityTwiceCountsItOnce() {
        let fixture = Fixture()
        fixture.monitor.start()
        let first = fixture.monitor.begin()
        let second = fixture.monitor.begin()

        first.end()
        first.end()
        fixture.scheduler.runPending()
        #expect(fixture.exits.count == 0, "the second activity is still open")

        second.end()
        fixture.scheduler.runPending()
        #expect(fixture.exits.count == 1)
    }

    /// Review focus 1: a Wega update installs on a worker queue after its request's connection has
    /// closed. The helper must outlive any number of idle minutes until the installation is over, or
    /// the installation's record turns `unknown` at the next start [O11].
    @Test func anInstallationKeepsTheHelperAliveAfterItsConnectionCloses() {
        let fixture = Fixture()
        fixture.monitor.start()
        let connection = fixture.monitor.begin()
        let request = fixture.monitor.begin()
        let installation = fixture.monitor.begin()
        request.end()
        connection.end()

        for _ in 1...5 {
            fixture.scheduler.runPending()
        }
        #expect(fixture.exits.count == 0, "the installation is still running")

        installation.end()
        #expect(fixture.scheduler.delays == [.seconds(60)])
        fixture.scheduler.runPending()
        #expect(fixture.exits.count == 1)
    }

    /// E.4: the decision and the exit hold the lock `begin()` takes, so a connection the delegate is
    /// accepting either counts before the decision or never meets a live process.
    @Test func theExitIsDecidedAndTakenUnderTheLockBeginTakes() {
        let fixture = Fixture()
        fixture.monitor.start()
        fixture.scheduler.runPending()

        #expect(fixture.exits.lockHeldAtExit == [true])
    }

    @Test func startingTwiceArmsOneCheck() {
        let fixture = Fixture()
        fixture.monitor.start()
        fixture.monitor.start()

        #expect(fixture.scheduler.delays == [.seconds(60)])
    }

    @Test func theIntervalIsTheOneGiven() {
        let fixture = Fixture(idleInterval: .seconds(5))
        fixture.monitor.start()

        #expect(fixture.scheduler.delays == [.seconds(5)])
    }

    /// The daemon's live scheduler hands the whole interval to Dispatch.
    @Test func theLiveSchedulerWaitsTheWholeInterval() {
        #expect(HelperIdleMonitor.dispatchInterval(.seconds(60)) == .nanoseconds(60_000_000_000))
        #expect(HelperIdleMonitor.dispatchInterval(.milliseconds(1_500)) == .nanoseconds(1_500_000_000))
    }
}

// MARK: - Fakes

private struct Fixture {
    let scheduler = FakeScheduler()
    let exits = ExitRecorder()
    let monitor: HelperIdleMonitor

    init(idleInterval: Duration? = nil) {
        let scheduler = scheduler
        let exits = exits
        let schedule: HelperIdleMonitor.Schedule = { delay, check in scheduler.add(delay, check) }
        let exit: @Sendable () -> Void = { exits.record() }
        if let idleInterval {
            monitor = HelperIdleMonitor(idleInterval: idleInterval, schedule: schedule, exit: exit)
        } else {
            monitor = HelperIdleMonitor(schedule: schedule, exit: exit)
        }
        exits.watch(monitor)
    }
}

/// Holds the checks the monitor scheduled until a test lets their time come.
private final class FakeScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var checks: [(delay: Duration, run: @Sendable () -> Void)] = []

    func add(_ delay: Duration, _ run: @escaping @Sendable () -> Void) {
        lock.withLock { checks.append((delay, run)) }
    }

    /// The delays of the checks still pending, oldest first.
    var delays: [Duration] {
        lock.withLock { checks.map(\.delay) }
    }

    /// The oldest pending check comes due.
    func runOldest() {
        let check = lock.withLock { checks.isEmpty ? nil : checks.removeFirst() }
        check?.run()
    }

    /// Every check pending now comes due; one they schedule waits for the next call.
    func runPending() {
        let due = lock.withLock {
            defer { checks.removeAll() }
            return checks
        }
        due.forEach { $0.run() }
    }
}

/// Counts exits and notes whether the monitor's lock was held when each was taken.
private final class ExitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var exitsHeldLock: [Bool] = []
    private weak var monitor: HelperIdleMonitor?

    func watch(_ monitor: HelperIdleMonitor) {
        lock.withLock { self.monitor = monitor }
    }

    func record() {
        let watched = lock.withLock { monitor }
        var held = true
        if let watched, watched.lock.try() {
            watched.lock.unlock()
            held = false
        }
        lock.withLock { exitsHeldLock.append(held) }
    }

    var count: Int {
        lock.withLock { exitsHeldLock.count }
    }

    var lockHeldAtExit: [Bool] {
        lock.withLock { exitsHeldLock }
    }
}
