import Foundation

/// The result of one Cleanup scan. Totals are computed from the findings, so they always agree.
public struct CleanupReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let createdAt: Date
    public let path: CleanupPathSnapshot
    public let findings: [CleanupFinding]
    public let notes: [CleanupDetectorNote]
    public let skippedProtected: [String]
    public let totals: CleanupTotals

    public init(
        createdAt: Date, path: CleanupPathSnapshot, findings: [CleanupFinding],
        notes: [CleanupDetectorNote], skippedProtected: [String]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.createdAt = createdAt
        self.path = path
        self.findings = findings
        self.notes = notes
        self.skippedProtected = skippedProtected
        totals = CleanupTotals.sum(findings)
    }
}

/// The JSON export (also the persisted form) and the plain-text export. Both show `~` instead of
/// the home directory and never carry process arguments.
public enum CleanupReportRenderer {
    public static func json(_ report: CleanupReport, home: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try CleanupHomeText(home: home).abbreviating(encoder.encode(report))
    }

    /// The inverse of `json`: `~` is expanded against `home` before decoding.
    static func report(fromJSON data: Data, home: URL) throws -> CleanupReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CleanupReport.self, from: CleanupHomeText(home: home).expanding(data))
    }

    /// One line per finding: detector, status, path, size, action, reason and, for an item in use,
    /// the processes by name and PID. Status and reason wording comes from the closures, which see
    /// `~` paths and processes without arguments; actions are written as commands or identifiers.
    public static func text(
        _ report: CleanupReport, home: URL,
        reasonText: (CleanupReason) -> String, statusText: (CleanupStatus) -> String
    ) -> String {
        report.findings.map { finding in
            let status = displayed(finding.status, home: home)
            var fields = [
                finding.detector.rawValue,
                statusText(status),
                tildePath(finding.path.path, home: home),
                finding.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "-",
                actionText(finding.action, home: home),
                reasonText(displayed(finding.reason, home: home)),
            ]
            if case .inUse(let processes) = status {
                fields.append(processes.map { "\($0.name) (PID \($0.pid))" }.joined(separator: ", "))
            }
            return fields.joined(separator: " | ") + "\n"
        }.joined()
    }

    /// `path` with the home prefix replaced by `~`, compared by whole scalar-split components, so
    /// `/Users/dom` never matches inside `/Users/dominik`. Other paths are returned unchanged.
    public static func tildePath(_ path: String, home: URL) -> String {
        let homeComponents = CleanupPathText.components(of: home.path)
        let components = CleanupPathText.components(of: path)
        guard !homeComponents.isEmpty, CleanupPathText.isAbsolute(path), components.starts(with: homeComponents) else {
            return path
        }
        let rest = components.dropFirst(homeComponents.count)
        return rest.isEmpty ? "~" : "~/" + rest.joined(separator: "/")
    }

    /// A command with `~` for the home in every word that is an absolute path. Commands are built
    /// from tokens that hold no space, so splitting on spaces finds every word.
    private static func tildeWords(_ command: String, home: URL) -> String {
        command.unicodeScalars.split(separator: " ", omittingEmptySubsequences: false)
            .map { tildePath(String(String.UnicodeScalarView($0)), home: home) }
            .joined(separator: " ")
    }

    private static func displayed(_ status: CleanupStatus, home: URL) -> CleanupStatus {
        guard case .inUse(let processes) = status else { return status }
        return .inUse(processes.map {
            CleanupProcess(pid: $0.pid, name: $0.name, executablePath: tildePath($0.executablePath, home: home), arguments: [])
        })
    }

    private static func displayed(_ reason: CleanupReason, home: URL) -> CleanupReason {
        guard case .shadowedBy(let path) = reason else { return reason }
        return .shadowedBy(path: tildePath(path, home: home))
    }

    private static func actionText(_ action: CleanupAction, home: URL) -> String {
        switch action {
        case .trash(let urls):
            "trash " + urls.map { tildePath($0.path, home: home) }.joined(separator: ", ")
        case .trashBatch(let parent, let entries):
            "trash-batch \(tildePath(parent.path, home: home)) (\(entries.count))"
        case .brew(.uninstallFormula(let name)):
            "brew uninstall -- \(name)"
        case .brew(.uninstallCask(let token)):
            "brew uninstall --cask -- \(token)"
        case .command(let command):
            tildeWords(command, home: home)
        case .instruction(.removeWithCreatingTool):
            "instruction remove-with-creating-tool"
        case .instruction(.removeAppLinkWithAdminRights(let link)):
            "instruction remove-app-link-with-admin-rights \(tildePath(link, home: home))"
        case .none:
            "-"
        }
    }
}

/// Swaps the home directory for `~` in the JSON text `CleanupReportRenderer` writes, and back.
///
/// It works on UTF-8 bytes, so matching is by Unicode scalars. The home is replaced in both of its
/// spellings, as path text and as a percent-encoded `file://` URL, wherever it is followed by `/`
/// or by the closing quote of a string, so `/Users/dom` never matches inside `/Users/dominik`.
/// Every `~` already in the text is first written as its JSON `\u` escape, so each literal `~`
/// left stands for the home and `expanding` restores exactly what was encoded. A path-text match
/// right after `file://` gets that prefix written as `file:\/\/`, so on the way back it is not
/// taken for the URL spelling (the encoder never escapes slashes itself).
private struct CleanupHomeText {
    private static let tilde = UInt8(ascii: "~")
    /// The six-byte JSON escape of `~`: a backslash, `u`, then `007e`.
    private static let escapedTilde = Array(#"\u"#.utf8) + Array("007e".utf8)
    private static let fileScheme = Array("file://".utf8)
    private static let escapedFileScheme = Array(#"file:\/\/"#.utf8)
    private static let boundaries: Set<UInt8> = [UInt8(ascii: "/"), UInt8(ascii: "\"")]

    private let pathSpelling: [UInt8]?
    private let urlSpelling: [UInt8]?

    init(home: URL) throws {
        let components = CleanupPathText.components(of: home.path)
        guard !components.isEmpty else {
            pathSpelling = nil
            urlSpelling = nil
            return
        }
        let path = "/" + components.joined(separator: "/")
        pathSpelling = try Self.spelling(of: path)
        urlSpelling = try Self.spelling(of: URL(filePath: path, directoryHint: .notDirectory).absoluteString)
    }

    func abbreviating(_ json: Data) -> Data {
        let escaped = Self.escapingTildes(Array(json))
        guard let pathSpelling, let urlSpelling else { return Data(escaped) }
        let urls = Self.replacing(urlSpelling, in: escaped) { $0 += Self.fileScheme + [Self.tilde] }
        let paths = Self.replacing(pathSpelling, in: urls) { output in
            if output.count >= Self.fileScheme.count, output.suffix(Self.fileScheme.count).elementsEqual(Self.fileScheme) {
                output.removeLast(Self.fileScheme.count)
                output += Self.escapedFileScheme
            }
            output.append(Self.tilde)
        }
        return Data(paths)
    }

    func expanding(_ json: Data) -> Data {
        guard let pathSpelling, let urlSpelling else { return json }
        let bytes = Array(json)
        let urlMarker = Self.fileScheme + [Self.tilde]
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index...].starts(with: urlMarker) {
                output += urlSpelling
                index += urlMarker.count
            } else if bytes[index] == Self.tilde {
                output += pathSpelling
                index += 1
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return Data(output)
    }

    /// `text` as it appears inside a JSON string written by the renderer, with `~` escaped.
    private static func spelling(of text: String) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return escapingTildes(Array(try encoder.encode(text).dropFirst().dropLast()))
    }

    private static func escapingTildes(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte == tilde { output += escapedTilde } else { output.append(byte) }
        }
        return output
    }

    private static func replacing(
        _ needle: [UInt8], in bytes: [UInt8], with append: (inout [UInt8]) -> Void
    ) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let end = index + needle.count
            if end < bytes.count, boundaries.contains(bytes[end]), bytes[index..<end].elementsEqual(needle) {
                append(&output)
                index = end
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }
}

/// Persists the last report, in the same `~` form as the JSON export, so the Cleanup destination
/// opens with a result.
public struct CleanupReportFile {
    private let io: ScanSnapshotIO
    private let home: URL

    public init(home: URL, io: ScanSnapshotIO = FileScanSnapshotIO(fileURL: CleanupReportFile.defaultFileURL)) {
        self.home = home
        self.io = io
    }

    /// Fail-soft: missing, unreadable, corrupt or other-schema data all read as nil.
    public func load() -> CleanupReport? {
        guard let data = try? io.read(),
              let report = try? CleanupReportRenderer.report(fromJSON: data, home: home),
              report.schemaVersion == CleanupReport.currentSchemaVersion
        else { return nil }
        return report
    }

    public func save(_ report: CleanupReport) throws {
        try io.write(CleanupReportRenderer.json(report, home: home))
    }

    /// `~/Library/Application Support/WegaMacUpdater/cleanup-report.json`.
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return base.appending(path: "WegaMacUpdater/cleanup-report.json", directoryHint: .notDirectory)
    }
}
