import Foundation

/// M2(b): the persisted result of one full update scan. Written after every scan
/// so a cold launch can paint the last known update list **immediately** — with an
/// honest freshness stamp ("znaleziono wczoraj o 21:14") from ``scannedAt`` — instead
/// of showing an empty window and re-scanning from zero.
///
/// `schemaVersion` is the forward-compatibility guard: a file written by a newer
/// build (or an older shape) is rejected on read (see ``ScanResultStore/load()``)
/// rather than decoded into a struct it no longer matches.
public struct ScanSnapshot: Codable, Equatable, Sendable {
    /// The schema this build reads and writes. Bump when the payload shape changes
    /// incompatibly; older/newer files then fail soft to `nil` on load.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var scannedAt: Date
    public var brew: BrewOutdated
    public var mas: [MasOutdatedApp]
    public var npm: [NpmGlobalOutdated]
    public var manual: [ManualOutdatedApp]

    public init(
        scannedAt: Date,
        brew: BrewOutdated,
        mas: [MasOutdatedApp],
        npm: [NpmGlobalOutdated],
        manual: [ManualOutdatedApp],
        schemaVersion: Int = ScanSnapshot.currentSchemaVersion
    ) {
        self.scannedAt = scannedAt
        self.brew = brew
        self.mas = mas
        self.npm = npm
        self.manual = manual
        self.schemaVersion = schemaVersion
    }
}

/// Narrow I/O seam so ``ScanResultStore`` can be unit-tested against an in-memory
/// double — the test suite never touches the disk. `read()` returns `nil` when
/// nothing has been persisted yet.
public protocol ScanSnapshotIO {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// Default file-backed I/O: one JSON file under the app's Application Support
/// directory. Read/write errors surface to the caller; ``ScanResultStore`` decides
/// the fail-soft policy on read.
public struct FileScanSnapshotIO: ScanSnapshotIO {
    private let fileURL: URL

    /// The production location: `~/Library/Application Support/WegaMacUpdater/last-scan.json`.
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("WegaMacUpdater", isDirectory: true)
            .appendingPathComponent("last-scan.json")
    }

    public init(fileURL: URL = FileScanSnapshotIO.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Persists and restores the most recent ``ScanSnapshot`` through an injected
/// ``ScanSnapshotIO``. Reads are **fail-soft**: missing data, corrupted JSON, an
/// I/O error, or an unrecognized ``ScanSnapshot/schemaVersion`` all yield `nil`
/// rather than throwing or crashing — a stale cache must never block a cold launch.
/// Writes overwrite and do surface errors so the caller can log a failed persist.
public struct ScanResultStore {
    private let io: ScanSnapshotIO

    public init(io: ScanSnapshotIO = FileScanSnapshotIO()) {
        self.io = io
    }

    /// Returns the persisted snapshot, or `nil` when nothing usable is on disk.
    public func load() -> ScanSnapshot? {
        guard let data = try? io.read() else { return nil }
        guard let snapshot = try? JSONDecoder().decode(ScanSnapshot.self, from: data) else { return nil }
        guard snapshot.schemaVersion == ScanSnapshot.currentSchemaVersion else { return nil }
        return snapshot
    }

    /// Overwrites the persisted snapshot. Propagates encoding/write failures.
    public func save(_ snapshot: ScanSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try io.write(data)
    }
}
