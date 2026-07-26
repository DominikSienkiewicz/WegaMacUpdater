import Foundation
import WegaHelperKit

// Privileged daemon entry point (FEAT-01). Runs as root under launchd, started
// on-demand when the app opens the XPC Mach service. It exposes ONLY the finite
// `WegaPrivilegedOps` whitelist and pins the client's code signature on every
// connection — there is deliberately no generic "run command as root" verb.
//
// SEC-10: this process links only `WegaHelperKit` (shared contract + root-side
// validation), not the full `MacUpdaterCore` (HTTP, parsers, UI helpers) — the
// privileged binary carries the minimal code it actually needs.

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: WegaHelper.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
