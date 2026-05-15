import Foundation
import MacUpdaterCore
import OSLog

let logger = Logger(subsystem: AppLogger.subsystem, category: "PrivilegedHelper")

logger.info("\(AppMetadata.displayName) privileged helper started")

// XPC listener setup belongs here once the app bundle contains the signed
// LaunchDaemon plist and Mach service entitlement. The helper must only expose
// typed allowlisted operations; it must never accept an arbitrary shell command.
RunLoop.main.run()
