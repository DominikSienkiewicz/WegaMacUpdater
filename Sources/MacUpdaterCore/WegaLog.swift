import OSLog

public enum WegaLog {
    public static func debug(_ category: LogCategory, _ message: String)   { log(.debug, category, message) }
    public static func info(_ category: LogCategory, _ message: String)    { log(.info, category, message) }
    public static func warning(_ category: LogCategory, _ message: String) { log(.warning, category, message) }
    public static func error(_ category: LogCategory, _ message: String)   { log(.error, category, message) }

    public static func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, category: category, message: message)

        let logger = osLogger(for: category)
        switch level {
        case .debug:   logger.debug("\(message, privacy: .public)")
        case .info:    logger.info("\(message, privacy: .public)")
        case .warning: logger.notice("\(message, privacy: .public)")
        case .error:   logger.error("\(message, privacy: .public)")
        }

        Task { @MainActor in LogStore.shared.append(entry) }
    }

    private static func osLogger(for category: LogCategory) -> Logger {
        switch category {
        case .app:      return AppLogger.app
        case .process:  return AppLogger.process
        case .homebrew: return AppLogger.homebrew
        case .scanner:  return AppLogger.scanner
        case .network:  return AppLogger.network
        case .helper:   return AppLogger.helper
        }
    }
}
