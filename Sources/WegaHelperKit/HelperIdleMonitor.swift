import Foundation

/// Decides when the root helper may exit because nothing needs it (R2-4).
///
/// launchd starts the helper on demand for its Mach service, so an idle helper can exit and the next
/// connection starts the binary of the current app bundle. One activity is an open connection, a
/// running `WegaPrivilegedOps` method or a background installation. Whenever the count of activities
/// drops to zero, and at `start()`, one check is scheduled `idleInterval` later. The check exits only
/// when the count is still zero and the generation, which every `begin()` and the first `end()` of
/// each activity bump, is the one it was armed with. The decision and the exit hold the lock
/// `begin()` takes, so a connection the delegate accepts is either counted before the decision or
/// never meets a live process.
public final class HelperIdleMonitor: @unchecked Sendable {
    /// Runs `check` once, `delay` from now, and returns before it runs.
    public typealias Schedule = @Sendable (_ delay: Duration, _ check: @escaping @Sendable () -> Void) -> Void

    /// Guards every field below; `begin()`, `end()` and the expiry check all take it.
    let lock = NSLock()
    private let idleInterval: Duration
    private let schedule: Schedule
    private let exitProcess: @Sendable () -> Void
    private var openTokens: Set<UInt64> = []
    private var lastToken: UInt64 = 0
    private var generation: UInt64 = 0
    private var isStarted = false

    /// - Parameters:
    ///   - idleInterval: how long the helper waits with nothing open before it exits.
    ///   - schedule: runs an expiry check later; the daemon passes `scheduleOnGlobalQueue`.
    ///   - exit: ends the process; it runs under the monitor's lock and must not call back into it.
    public init(idleInterval: Duration = .seconds(60), schedule: @escaping Schedule, exit: @escaping @Sendable () -> Void) {
        self.idleInterval = idleInterval
        self.schedule = schedule
        self.exitProcess = exit
    }

    /// Arms the first check: launchd may have started the helper for a connection that never arrived.
    /// Nothing is armed before this; a second call changes nothing.
    public func start() {
        let armed: UInt64? = lock.withLock {
            guard !isStarted else { return nil }
            isStarted = true
            return generationToArm()
        }
        arm(armed)
    }

    /// One more open connection or piece of work: the helper does not exit before its `end()`.
    public func begin() -> Activity {
        lock.withLock {
            lastToken += 1
            openTokens.insert(lastToken)
            generation += 1
            return Activity(monitor: self, token: lastToken)
        }
    }

    private func end(_ token: UInt64) {
        let armed: UInt64? = lock.withLock {
            guard openTokens.remove(token) != nil else { return nil }
            generation += 1
            return generationToArm()
        }
        arm(armed)
    }

    /// The generation a check should be armed with now, or nil when none is due. Caller holds `lock`.
    private func generationToArm() -> UInt64? {
        isStarted && openTokens.isEmpty ? generation : nil
    }

    private func arm(_ armed: UInt64?) {
        guard let armed else { return }
        schedule(idleInterval) { [self] in expire(armedAt: armed) }
    }

    private func expire(armedAt armed: UInt64) {
        lock.withLock {
            guard openTokens.isEmpty, generation == armed else { return }
            exitProcess()
        }
    }

    /// One open connection or piece of work. `end()` closes it; a second `end()` changes nothing.
    public final class Activity: Sendable {
        private let monitor: HelperIdleMonitor
        private let token: UInt64

        fileprivate init(monitor: HelperIdleMonitor, token: UInt64) {
            self.monitor = monitor
            self.token = token
        }

        public func end() {
            monitor.end(token)
        }
    }

    /// The daemon's `schedule`: runs `check` once on a global queue after `delay`.
    public static let scheduleOnGlobalQueue: Schedule = { delay, check in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + dispatchInterval(delay), execute: check)
    }

    static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
