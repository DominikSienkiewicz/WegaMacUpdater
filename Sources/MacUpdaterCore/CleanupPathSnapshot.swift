import Foundation

/// The `PATH` the Cleanup feature searches: read from the user's login shell, or approximated.
public struct CleanupPathSnapshot: Codable, Equatable, Sendable {
    public var entries: [String]
    public var ignoredEntries: [String]
    public var shell: String?
    public var capturedAt: Date?
    public var isApproximate: Bool

    public init(entries: [String], ignoredEntries: [String], shell: String?, capturedAt: Date?, isApproximate: Bool) {
        self.entries = entries
        self.ignoredEntries = ignoredEntries
        self.shell = shell
        self.capturedAt = capturedAt
        self.isApproximate = isApproximate
    }
}

public enum CleanupPathReadResult: Equatable, Sendable {
    case captured(CleanupPathSnapshot)
    case unsupportedShell(String)
    case failed
}

/// Reads the user's real `PATH` by running their login shell once, on an explicit user action.
/// A Finder-launched app only inherits `/usr/bin:/bin:/usr/sbin:/sbin`. Shell output (banners,
/// errors) may carry secrets, so only the text between the markers is used and nothing of it is
/// stored, logged or returned beyond the parsed entries.
public struct CleanupPathReader: Sendable {
    private static let beginMarker = "__WEGA_PATH_BEGIN__"
    private static let endMarker = "__WEGA_PATH_END__"
    private static let scriptBody = "\"\(beginMarker)${PATH}\(endMarker)\""
    private static let scripts = [
        "zsh": "print -rn -- \(scriptBody)",
        "bash": "printf '%s' \(scriptBody)",
    ]

    private let runner: ProcessRunning
    private let shellPath: String
    private let home: URL
    private let user: String
    private let now: @Sendable () -> Date

    public init(runner: ProcessRunning, shellPath: String, home: URL, user: String, now: @escaping @Sendable () -> Date) {
        self.runner = runner
        self.shellPath = shellPath
        self.home = home
        self.user = user
        self.now = now
    }

    public func read() async -> CleanupPathReadResult {
        let shell = Self.shellName(shellPath)
        guard let request = Self.request(shellPath: shellPath, home: home, user: user) else {
            return .unsupportedShell(shell)
        }
        guard let result = try? await runner.run(request), result.exitCode == 0,
              let parsed = Self.parse(stdout: result.stdout)
        else { return .failed }
        return .captured(CleanupPathSnapshot(
            entries: parsed.entries, ignoredEntries: parsed.ignored,
            shell: shell, capturedAt: now(), isApproximate: false
        ))
    }

    public static func request(shellPath: String, home: URL, user: String) -> ProcessRequest? {
        guard let script = scripts[shellName(shellPath)] else { return nil }
        let environment = [
            "HOME": home.path, "USER": user, "LOGNAME": user, "SHELL": shellPath,
            "LANG": "en_US.UTF-8", "TERM": "dumb", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        var request = ProcessRequest(
            executableURL: URL(filePath: shellPath, directoryHint: .notDirectory),
            arguments: ["-ilc", script],
            environment: environment,
            inheritParentEnvironment: false,
            timeout: 10,
            idleTimeout: 10
        )
        request.standardInput = .nullDevice
        request.outputLogging = .suppressed
        return request
    }

    /// Entries between the markers, split on `:` by scalars. Empty and relative entries are set
    /// aside in `ignored`; order and duplicates are kept. Nil when the markers are missing.
    public static func parse(stdout: String) -> (entries: [String], ignored: [String])? {
        let scalars = Array(stdout.unicodeScalars)
        guard let begin = find(Array(beginMarker.unicodeScalars), in: scalars, from: 0),
              let end = find(Array(endMarker.unicodeScalars), in: scalars, from: begin + beginMarker.unicodeScalars.count)
        else { return nil }
        let body = scalars[(begin + beginMarker.unicodeScalars.count)..<end]
        var entries: [String] = []
        var ignored: [String] = []
        for segment in body.split(separator: ":", omittingEmptySubsequences: false) {
            var text = String.UnicodeScalarView()
            text.append(contentsOf: segment)
            let entry = String(text)
            if CleanupPathText.isAbsolute(entry), !CleanupPathText.containsNUL(entry) {
                entries.append(entry)
            } else {
                ignored.append(entry)
            }
        }
        return (entries, ignored)
    }

    private static func shellName(_ path: String) -> String {
        CleanupPathText.components(of: path).last ?? ""
    }

    private static func find(_ needle: [Unicode.Scalar], in haystack: [Unicode.Scalar], from start: Int) -> Int? {
        guard haystack.count >= needle.count, start <= haystack.count - needle.count else { return nil }
        return (start...(haystack.count - needle.count)).first { haystack[$0..<($0 + needle.count)].elementsEqual(needle) }
    }
}

/// The `PATH` used when no shell read is stored: `/etc/paths`, `/etc/paths.d/*` and the
/// well-known tool directories that exist. Missing or unreadable files are skipped silently.
public enum CleanupApproximatePath {
    public static let knownDirectories: [String] = [
        ".local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", ".cargo/bin",
    ]

    private static let maximumFileBytes = 64 * 1024

    public static func build(fileSystem: CleanupFileSystem, home: URL) -> CleanupPathSnapshot {
        var entries = absoluteLines(of: "/etc/paths", in: fileSystem)
        let directory = URL(filePath: "/etc/paths.d", directoryHint: .isDirectory)
        let files = ((try? fileSystem.contents(of: directory)) ?? []).sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        for file in files {
            entries += absoluteLines(of: file.url.path, in: fileSystem)
        }
        for known in knownDirectories {
            let path = CleanupPathText.isAbsolute(known)
                ? known
                : home.appending(path: known, directoryHint: .isDirectory).path
            let url = URL(filePath: path, directoryHint: .isDirectory)
            guard !entries.contains(path), (try? fileSystem.entry(at: url)) != nil else { continue }
            entries.append(path)
        }
        return CleanupPathSnapshot(entries: entries, ignoredEntries: [], shell: nil, capturedAt: nil, isApproximate: true)
    }

    private static func absoluteLines(of path: String, in fileSystem: CleanupFileSystem) -> [String] {
        let url = URL(filePath: path, directoryHint: .notDirectory)
        guard let text = try? fileSystem.readText(url, maxBytes: maximumFileBytes) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { CleanupPathText.isAbsolute($0) && !CleanupPathText.containsNUL($0) }
    }
}

/// Persists the last `PATH` read next to the other app data.
public struct CleanupPathSnapshotFile {
    private let io: ScanSnapshotIO

    public init(io: ScanSnapshotIO = FileScanSnapshotIO(fileURL: CleanupPathSnapshotFile.defaultFileURL)) {
        self.io = io
    }

    /// Fail-soft: missing, unreadable or corrupt data all read as nil.
    public func load() -> CleanupPathSnapshot? {
        guard let data = try? io.read() else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CleanupPathSnapshot.self, from: data)
    }

    public func save(_ snapshot: CleanupPathSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try io.write(encoder.encode(snapshot))
    }

    /// `~/Library/Application Support/WegaMacUpdater/cleanup-path.json`.
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return base.appending(path: "WegaMacUpdater/cleanup-path.json", directoryHint: .notDirectory)
    }
}
