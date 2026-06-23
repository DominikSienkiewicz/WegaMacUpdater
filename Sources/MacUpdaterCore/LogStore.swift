import Foundation

public enum LogLevel: String, Sendable, CaseIterable {
    case debug, info, warning, error
}

public enum LogCategory: String, Sendable, CaseIterable {
    case app, process, homebrew, scanner, network, helper

    /// Czytelna etykieta używana w linii pliku i w UI.
    public var label: String {
        switch self {
        case .app:      return "App"
        case .process:  return "Process"
        case .homebrew: return "Homebrew"
        case .scanner:  return "Scanner"
        case .network:  return "Network"
        case .helper:   return "Helper"
        }
    }

    static func from(label: String) -> LogCategory? {
        LogCategory.allCases.first { $0.label == label }
    }
}

public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String

    public init(id: UUID = UUID(), date: Date, level: LogLevel,
                category: LogCategory, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Linia pliku: `2026-06-09T17:34:01Z [ERROR] [Homebrew] message`
    public var fileLine: String {
        let flat = message.replacingOccurrences(of: "\n", with: " ")
                          .replacingOccurrences(of: "\r", with: " ")
        return "\(Self.isoFormatter.string(from: date)) [\(level.rawValue.uppercased())] [\(category.label)] \(flat)"
    }

    /// Parsuje linię pliku. Zwraca `nil` dla uszkodzonej/niepełnej linii.
    public static func parse(_ line: String) -> LogEntry? {
        let pattern = #"^(\S+) \[([A-Z]+)\] \[([^\]]+)\] (.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let m = re.firstMatch(in: line, range: range), m.numberOfRanges == 5,
              let isoR = Range(m.range(at: 1), in: line),
              let lvlR = Range(m.range(at: 2), in: line),
              let catR = Range(m.range(at: 3), in: line),
              let msgR = Range(m.range(at: 4), in: line) else { return nil }
        guard let date = isoFormatter.date(from: String(line[isoR])),
              let level = LogLevel(rawValue: String(line[lvlR]).lowercased()),
              let category = LogCategory.from(label: String(line[catR])) else { return nil }
        return LogEntry(date: date, level: level, category: category,
                        message: String(line[msgR]))
    }
}

@MainActor
public final class LogStore: ObservableObject {
    public static let shared = LogStore()

    @Published public private(set) var entries: [LogEntry] = []

    private let directory: URL
    private let memoryCap: Int
    private let fileMaxBytes: Int
    private let loadTailLines: Int
    private let fileQueue = DispatchQueue(label: "wega.logstore.file")

    public var logFileURL: URL { directory.appendingPathComponent("wega.log") }
    private var backupURL: URL { directory.appendingPathComponent("wega.log.1") }

    /// The real, production log location.
    public nonisolated static let userLogDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/WegaMacUpdater", isDirectory: true)

    /// Where `LogStore.shared` (and any default-constructed store) writes. Under
    /// XCTest this is redirected to a temp directory so the test suite can never
    /// pollute the user's real app log; production always uses `userLogDirectory`.
    public nonisolated static var defaultDirectory: URL {
        isRunningUnderTests
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("WegaMacUpdaterTests/Logs", isDirectory: true)
            : userLogDirectory
    }

    /// True when the process is hosting the XCTest framework (i.e. `swift test`).
    /// The app bundle never loads XCTest, so this stays false in production.
    nonisolated static var isRunningUnderTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    public init(
        directory: URL = LogStore.defaultDirectory,
        memoryCap: Int = 2000,
        fileMaxBytes: Int = 5 * 1024 * 1024,
        loadTailLines: Int = 2000
    ) {
        self.directory = directory
        self.memoryCap = memoryCap
        self.fileMaxBytes = fileMaxBytes
        self.loadTailLines = loadTailLines
        loadFromFile()
    }

    public func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > memoryCap { entries.removeFirst(entries.count - memoryCap) }
        let line = entry.fileLine
        let dir = directory
        let fileURL = logFileURL
        let backup = backupURL
        let maxBytes = fileMaxBytes
        fileQueue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            Self.rotateIfNeeded(fileURL: fileURL, backup: backup, maxBytes: maxBytes,
                                incoming: line.utf8.count + 1)
            Self.appendLine(line, to: fileURL)
        }
    }

    public func clear() {
        entries.removeAll()
        let fileURL = logFileURL
        let backup = backupURL
        fileQueue.sync {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: backup)
        }
    }

    /// Blokuje do opróżnienia kolejki zapisu — wyłącznie do testów.
    public func flushForTests() {
        fileQueue.sync { /* bariera: pusty blok celowo — czeka aż kolejka zapisu się opróżni */ }
    }

    public func loadFromFile() {
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let tail = lines.suffix(loadTailLines)
        let parsed = tail.compactMap { LogEntry.parse($0) }
        entries = Array(parsed.suffix(memoryCap))
    }

    private static nonisolated func rotateIfNeeded(fileURL: URL, backup: URL, maxBytes: Int, incoming: Int) {
        let current = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int) ?? 0
        guard current + incoming > maxBytes, current > 0 else { return }
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    private static nonisolated func appendLine(_ line: String, to fileURL: URL) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
