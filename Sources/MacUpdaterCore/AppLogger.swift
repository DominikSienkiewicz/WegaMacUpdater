import OSLog

public enum AppLogger {
    public static let subsystem = AppMetadata.bundleIdentifier

    public static let app = Logger(subsystem: subsystem, category: "App")
    public static let process = Logger(subsystem: subsystem, category: "Process")
    public static let homebrew = Logger(subsystem: subsystem, category: "Homebrew")
    public static let scanner = Logger(subsystem: subsystem, category: "Scanner")
    public static let helper = Logger(subsystem: subsystem, category: "Helper")
    public static let network = Logger(subsystem: subsystem, category: "Network")
}
