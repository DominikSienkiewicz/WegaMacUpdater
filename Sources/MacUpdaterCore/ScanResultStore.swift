import Foundation

/// REL-09 — what one source of a scan answered, and what it said when it did not.
///
/// The verdict itself is `SourceCheckOutcome`, the same enum the live scan already
/// classifies its sources with; this only adds the detail that used to exist for the
/// length of one log line — *why* it failed — and makes the pair storable.
public struct ScanSourceReport: Codable, Equatable, Sendable {
    public var outcome: SourceCheckOutcome
    /// The failure, in the source's own words. `nil` for anything but `.failed`.
    public var error: String?

    public init(outcome: SourceCheckOutcome, error: String? = nil) {
        self.outcome = outcome
        self.error = error
    }

    /// A source that is not installed is *not applicable*, never a failure (F4) — the
    /// distinction that keeps a machine without Homebrew from wearing a permanent red badge.
    public var didFail: Bool {
        if case .failed = outcome { return true }
        return false
    }
}

/// REL-09 — the per-source picture of one scan: exactly which of them answered.
///
/// A scan used to be persisted as four lists and a timestamp, which cannot express the
/// difference between "Brew reported nothing outdated" and "Brew never answered". `nil`
/// here means the scan never got that far (it was cancelled, or the phase was skipped).
public struct ScanSourceReports: Codable, Equatable, Sendable {
    /// `brew update` — the metadata refresh. Its failure does not empty the list, it makes
    /// the list *stale*, which is just as much a reason not to claim "everything is current".
    public var brewMetadata: ScanSourceReport?
    /// `brew outdated`.
    public var brew: ScanSourceReport?
    public var mas: ScanSourceReport?
    public var npm: ScanSourceReport?
    /// The manual per-app checkers, as one source: they are dozens of endpoints, and the
    /// snapshot cares whether any of them went silent, not which.
    public var manual: ScanSourceReport?

    public init(
        brewMetadata: ScanSourceReport? = nil,
        brew: ScanSourceReport? = nil,
        mas: ScanSourceReport? = nil,
        npm: ScanSourceReport? = nil,
        manual: ScanSourceReport? = nil
    ) {
        self.brewMetadata = brewMetadata
        self.brew = brew
        self.mas = mas
        self.npm = npm
        self.manual = manual
    }

    public var all: [ScanSourceReport] { [brewMetadata, brew, mas, npm, manual].compactMap { $0 } }

    /// True only when nothing failed. An absent report is not a failure — a lightweight
    /// post-upgrade re-query legitimately skips the metadata refresh.
    public var isComplete: Bool { !all.contains { $0.didFail } }

    /// How many sources went silent. Counts the manual checkers as one, unlike the live
    /// scan's own tally, which names each failed endpoint while it still has them.
    public var failedSourceCount: Int { all.filter(\.didFail).count }

    /// The failures, in the words of the sources themselves — what a banner shows and what
    /// the log repeats after a restart, when the original scan log is long gone.
    public var errors: [String] { all.compactMap(\.error) }
}

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
    ///
    /// 2 — REL-09 added the per-source results and the completeness flag. A version-1 file
    /// carries neither, and reading it as complete is exactly the false reassurance this
    /// bump exists to prevent, so it is rejected and the next scan writes a fresh one.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var scannedAt: Date
    /// `nil` when Brew never answered — which is **not** the same as an empty list, and was
    /// stored as one until REL-09.
    public var brew: BrewOutdated?
    public var mas: [MasOutdatedApp]
    public var npm: [NpmGlobalOutdated]
    public var manual: [ManualOutdatedApp]
    /// REL-09 — what each source of this scan answered.
    public var sources: ScanSourceReports
    /// REL-09 — whether this scan heard from every source it asked. Stored rather than
    /// derived on read, so a file written by a build with a different idea of completeness
    /// still means what it said at the time; defaults to what `sources` implies.
    public var isComplete: Bool

    public init(
        scannedAt: Date,
        brew: BrewOutdated?,
        mas: [MasOutdatedApp],
        npm: [NpmGlobalOutdated],
        manual: [ManualOutdatedApp],
        sources: ScanSourceReports = ScanSourceReports(),
        isComplete: Bool? = nil,
        schemaVersion: Int = ScanSnapshot.currentSchemaVersion
    ) {
        self.scannedAt = scannedAt
        self.brew = brew
        self.mas = mas
        self.npm = npm
        self.manual = manual
        self.sources = sources
        self.isComplete = isComplete ?? sources.isComplete
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
