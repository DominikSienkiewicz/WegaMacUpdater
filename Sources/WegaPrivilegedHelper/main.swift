import Foundation
import MacUpdaterCore

// Privileged daemon entry point (FEAT-01). Runs as root under launchd, started
// on-demand when the app opens the XPC Mach service. It exposes ONLY the finite
// `WegaPrivilegedOps` whitelist and pins the client's code signature on every
// connection — there is deliberately no generic "run command as root" verb.
//
// NOTE: minimal by design. For production hardening consider extracting the
// shared contract + verifier into a dedicated lightweight module so this root
// process does not link the full MacUpdaterCore (tracked as a follow-up).

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: WegaHelper.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
