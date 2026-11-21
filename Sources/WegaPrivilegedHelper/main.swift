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
            exit(EXIT_SUCCESS)
        }
    )
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: WegaHelper.machServiceName)
listener.delegate = delegate
HelperIdle.monitor.start()
listener.resume()
dispatchMain()
