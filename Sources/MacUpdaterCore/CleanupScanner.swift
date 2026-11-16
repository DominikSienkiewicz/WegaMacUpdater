import Foundation

/// Everything one Cleanup scan reads. Production passes the guarded live file system.
public struct CleanupContext: Sendable {
    public let home: URL
    public let tmpDirectory: URL
    public let path: CleanupPathSnapshot
    public let fileSystem: CleanupFileSystem
    public let inspector: ProcessInspecting
    public let brew: CleanupBrewQuerying
    public let brewPrefix: URL?

    public init(
        home: URL, tmpDirectory: URL, path: CleanupPathSnapshot, fileSystem: CleanupFileSystem,
        inspector: ProcessInspecting, brew: CleanupBrewQuerying, brewPrefix: URL?
    ) {
        self.home = home
        self.tmpDirectory = tmpDirectory
        self.path = path
        self.fileSystem = fileSystem
        self.inspector = inspector
        self.brew = brew
        self.brewPrefix = brewPrefix
    }
}

/// Runs the stage-1 detectors in order — the `PATH` scan (D1), version directories (D3), the
/// D1 findings with their Homebrew checks, then per-shell state (D8) — and totals the result.
///
/// Each detector is its own failure domain: one that throws leaves a `.failed` note and the others
/// still report. Cancellation is checked before every detector and before the report is built, so
/// a cancelled scan throws `CancellationError` and returns nothing; sizing inside a detector
/// swallows its errors, so a cancellation raised there is seen at the next check.
public struct CleanupScanner: Sendable {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func scan(_ context: CleanupContext) async throws -> CleanupReport {
        let fileSystem = context.fileSystem
        let classifier = CleanupSourceClassifier(home: context.home, brewPrefix: context.brewPrefix)

        try Task.checkCancellation()
        let pathScan = CleanupPathDuplicateDetector(fileSystem: fileSystem, classifier: classifier).scan(context.path)

        try Task.checkCancellation()
        let versionFindings = CleanupVersionDirectoryDetector(
            fileSystem: fileSystem, home: context.home, inspector: context.inspector
        ).findings(pathScan: pathScan)

        try Task.checkCancellation()
        let duplicates = await CleanupDuplicateFindings(
            brew: context.brew, inspector: context.inspector, fileSystem: fileSystem,
            brewPrefix: context.brewPrefix, home: context.home
        ).build(pathScan)
        var notes = duplicates.notes

        try Task.checkCancellation()
        let shellFindings = try isolated(.shellState, notes: &notes) {
            try CleanupShellStateDetector(
                fileSystem: fileSystem, home: context.home, tmpDirectory: context.tmpDirectory,
                inspector: context.inspector
            ).findings()
        }

        try Task.checkCancellation()
        return CleanupReport(
            createdAt: now(), path: context.path, findings: duplicates.findings + versionFindings + shellFindings,
            notes: notes, skippedProtected: pathScan.skippedProtected
        )
    }

    /// The detector's findings, or none and a `.failed` note when it throws anything but a cancellation.
    private func isolated(
        _ detector: CleanupDetectorID, notes: inout [CleanupDetectorNote], _ body: () throws -> [CleanupFinding]
    ) throws -> [CleanupFinding] {
        do {
            return try body()
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            notes.append(CleanupDetectorNote(detector: detector, kind: .failed))
            return []
        }
    }
}
