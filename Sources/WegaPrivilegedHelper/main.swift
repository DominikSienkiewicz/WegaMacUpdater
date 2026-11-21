import Foundation
import OSLog
import WegaHelperKit

// Privileged daemon entry point (FEAT-01). Runs as root under launchd, started
// on-demand when the app opens the XPC Mach service. It exposes ONLY the finite
// `WegaPrivilegedOps` whitelist and pins the client's code signature on every
// connection — there is deliberately no generic "run command as root" verb.
//
// SEC-10: this process links only `WegaHelperKit` (shared contract + root-side
// validation), not the full `MacUpdaterCore` (HTTP, parsers, UI helpers) — the
// privileged binary carries the minimal code it actually needs.

/// R2-4: the one monitor of this process. The helper exits after a minute with no open connection
/// and no work; launchd starts the current bundle's binary for the next connection.
enum HelperIdle {
    static let logger = Logger(subsystem: WegaHelper.helperSigningID, category: "PrivilegedHelper")
    static let monitor = HelperIdleMonitor(
        schedule: HelperIdleMonitor.scheduleOnGlobalQueue,
        exit: {
            // `.notice` is persisted, so `log show` still finds the exit afterwards; `.info` is not.
            HelperIdle.logger.notice("Pomocnik kończy pracę po bezczynności")
            // Called under the monitor's lock: `_exit` runs no exit handler or static teardown that
            // could wait on a thread blocked on that lock.
            _exit(EXIT_SUCCESS)
        }
    )
}

// Z14: the bundle launchd started this process from, checked once before the first connection. A
// refusal is logged per connection by the delegate; the idle exit ends the process as usual.
let delegate = HelperListenerDelegate(bundleTrust: HelperBundleGate.trustOfThisHelper())
let listener = NSXPCListener(machServiceName: WegaHelper.machServiceName)
listener.delegate = delegate
HelperIdle.monitor.start()
listener.resume()
dispatchMain()
