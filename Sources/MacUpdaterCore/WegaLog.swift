import OSLog

public enum WegaLog {
    public static func debug(_ category: LogCategory, _ message: String, detail: LogDetail? = nil) {
        log(.debug, category, message, detail: detail)
    }
    public static func info(_ category: LogCategory, _ message: String, detail: LogDetail? = nil) {
        log(.info, category, message, detail: detail)
    }
    public static func warning(_ category: LogCategory, _ message: String, detail: LogDetail? = nil) {
        log(.warning, category, message, detail: detail)
    }
    public static func error(_ category: LogCategory, _ message: String, detail: LogDetail? = nil) {
        log(.error, category, message, detail: detail)
    }

    public static func log(_ level: LogLevel, _ category: LogCategory, _ message: String,
                           detail: LogDetail? = nil) {
        let entry = LogEntry(date: Date(), level: level, category: category,
                             message: message, detail: detail)

        // SEC-09: privacy is set per field. The category is structural, not user data,
        // so it stays `.public`; the message is user data and is `.private` by default —
        // OSLog renders it `<private>` to any other process reading the unified log. The
        // message is additionally redacted (paths and query strings stripped) so that even
        // a build configured to show private data cannot reconstruct the user's app profile
        // from the system log. The full, un-redacted line still reaches the `0600` `wega.log`.
        //
        // The failure detail carries the same class of data — a command line, a `stderr`
        // block — so it takes the same route: redacted, `.private`, folded onto the line.
        let logger = osLogger(for: category)
        let suffix = detail
            .map { " " + $0.redacted(using: LogRedaction.redact).continuationLines.joined(separator: " ") }
            ?? ""
        let text = LogRedaction.redact(message) + suffix
        switch level {
        case .debug:   logger.debug("\(category.label, privacy: .public): \(text, privacy: .private)")
        case .info:    logger.info("\(category.label, privacy: .public): \(text, privacy: .private)")
        case .warning: logger.notice("\(category.label, privacy: .public): \(text, privacy: .private)")
        case .error:   logger.error("\(category.label, privacy: .public): \(text, privacy: .private)")
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
