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
    /// The folders the project walk reads requirement files from, for D5 and D6.
    public let projectRoots: [URL]
    /// The folders D7 looks for installed JetBrains IDEs in.
    public let applicationDirectories: [URL]
    public let duplicateApplicationScan: ScanConfiguration?
    /// The "Files and Folders" database D10 reads; `nil` while the map is switched off, and D10 then does nothing.
    public let tccMap: CleanupTCCDatabaseReading?
    /// The folder holding the system shell files and `paths` that D9 attributes entries to.
    public let systemConfigurationDirectory: URL

    public init(
        home: URL, tmpDirectory: URL, path: CleanupPathSnapshot, fileSystem: CleanupFileSystem,
        inspector: ProcessInspecting, brew: CleanupBrewQuerying, brewPrefix: URL?,
        projectRoots: [URL] = [], applicationDirectories: [URL] = [],
        tccMap: CleanupTCCDatabaseReading? = nil, duplicateApplicationScan: ScanConfiguration? = nil,
        systemConfigurationDirectory: URL = URL(filePath: "/etc", directoryHint: .isDirectory)
    ) {
        self.home = home
        self.tmpDirectory = tmpDirectory
        self.path = path
        self.fileSystem = fileSystem
        self.inspector = inspector
        self.brew = brew
        self.brewPrefix = brewPrefix
        self.projectRoots = projectRoots
        self.applicationDirectories = applicationDirectories
        self.duplicateApplicationScan = duplicateApplicationScan
        self.tccMap = tccMap
        self.systemConfigurationDirectory = systemConfigurationDirectory
    }
}

/// Runs the detectors in order — the `PATH` scan (D1), version directories (D3), the D1 findings
/// with their Homebrew checks, Homebrew leftovers (D4), one walk over the project roots, runtime
/// versions (D5), Gradle (D6), JetBrains folders (D7), per-shell state (D8), `PATH` hygiene (D9,
/// from the D1 findings), then, only when the context carries a database, the "Files and Folders"
/// map (D10, linked to the D1 and D3 findings) — and totals the result. Every detector and the walk
/// get the context's file system, the guarded one in production.
///
/// Each detector is its own failure domain: one that throws leaves a `.failed` note and the others
/// still report; D4, D7 and D10 return their own notes, and the paths D9 was refused join the
/// report's `skippedProtected`. A walk that searched no project root, or was cut
/// short, leaves a note, because D5 and D6 may then miss a requirement; D6 then keeps every
/// distribution out of the safe bucket, as it does when the walk was refused a path (already listed
/// in `skippedProtected`), whose projects' wrappers went unread. Cancellation is checked before
/// every detector, by the walk before every directory, and before the report is built, so a
/// cancelled scan throws `CancellationError` and returns nothing; sizing inside a detector swallows
/// its errors, so a cancellation raised there is seen at the next check.
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
            brewPrefix: context.brewPrefix, home: context.home, pathIsApproximate: context.path.isApproximate
        ).build(pathScan)
        var notes = duplicates.notes

        try Task.checkCancellation()
        let homebrew = await CleanupHomebrewDetector(
            brew: context.brew, fileSystem: fileSystem, inspector: context.inspector,
            brewPrefix: context.brewPrefix, now: now()
        ).scan()
        notes += homebrew.notes

        try Task.checkCancellation()
        let walk = try CleanupProjectWalker(fileSystem: fileSystem).walk(roots: context.projectRoots)
        notes += Self.notes(for: walk)
        let projectFiles = Self.uniqueProjectFiles(walk.files)

        try Task.checkCancellation()
        let runtimeFindings = try isolated(.runtimeVersions, notes: &notes) {
            CleanupRuntimeVersionDetector(fileSystem: fileSystem, home: context.home, inspector: context.inspector)
                .findings(projectFiles: projectFiles)
        }

        try Task.checkCancellation()
        let walkIsComplete = walk.isComplete && walk.skippedProtected.isEmpty
        let gradleFindings = try isolated(.gradle, notes: &notes) {
            CleanupGradleDetector(fileSystem: fileSystem, home: context.home, inspector: context.inspector)
                .findings(projectFiles: projectFiles, walkIsComplete: walkIsComplete)
        }

        try Task.checkCancellation()
        let jetBrains = CleanupJetBrainsDetector(
            fileSystem: fileSystem, home: context.home, inspector: context.inspector,
            applicationDirectories: context.applicationDirectories
        ).findings()
        notes += jetBrains.notes

        try Task.checkCancellation()
        let shellFindings = try isolated(.shellState, notes: &notes) {
            try CleanupShellStateDetector(
                fileSystem: fileSystem, home: context.home, tmpDirectory: context.tmpDirectory,
                inspector: context.inspector
            ).findings()
        }

        try Task.checkCancellation()
        var hygieneSkipped: [String] = []
        let hygieneFindings = try isolated(.pathHygiene, notes: &notes) {
            let hygiene = CleanupPathHygieneDetector(
                fileSystem: fileSystem, home: context.home, systemConfigurationDirectory: context.systemConfigurationDirectory
            ).scan(context.path, duplicates: duplicates.findings)
            hygieneSkipped = hygiene.skippedProtected
            return hygiene.findings
        }

        try Task.checkCancellation()
        var mapFindings: [CleanupFinding] = []
        if let database = context.tccMap {
            var mapNotes: [CleanupDetectorNote] = []
            mapFindings = try isolated(.tccMap, notes: &notes) {
                let map = try CleanupTCCMapDetector(database: database, fileSystem: fileSystem)
                    .scan(linkingTo: duplicates.findings + versionFindings)
                mapNotes = map.notes
                return map.findings
            }
            notes += mapNotes
        }

        try Task.checkCancellation()
        let applicationCopies = try CleanupApplicationDuplicates(fileSystem: fileSystem).findings(
            home: context.home, configuration: context.duplicateApplicationScan, fallbackDirectories: context.applicationDirectories
        )
        try Task.checkCancellation()
        let findings = applicationCopies + duplicates.findings + versionFindings + homebrew.findings + runtimeFindings + gradleFindings
            + jetBrains.findings + shellFindings + hygieneFindings + mapFindings
        return CleanupReport(
            createdAt: now(), path: context.path, findings: findings, notes: notes,
            skippedProtected: Self.merged(Self.merged(pathScan.skippedProtected, walk.skippedProtected), hygieneSkipped)
        )
    }

    /// The walk's files with each physical path once, as first listed: nested or linked roots list
    /// a file once per root. Paths compare by their scalar components.
    static func uniqueProjectFiles(_ files: [CleanupProjectFile]) -> [CleanupProjectFile] {
        var seen: Set<[[Unicode.Scalar]]> = []
        return files.filter { file in
            seen.insert(CleanupPathText.components(of: file.url.path).map { Array($0.unicodeScalars) }).inserted
        }
    }

    /// No project root searched (none set, or every one missing, refused or unreadable), and a walk
    /// cut short, are separate reasons why D5 and D6 may miss a requirement.
    private static func notes(for walk: CleanupProjectWalk) -> [CleanupDetectorNote] {
        var notes: [CleanupDetectorNote] = []
        if walk.walkedRoots.isEmpty {
            notes.append(CleanupDetectorNote(detector: .runtimeVersions, kind: .noProjectRoots))
        }
        if walk.truncated {
            notes.append(CleanupDetectorNote(detector: .runtimeVersions, kind: .projectWalkTruncated))
        }
        return notes
    }

    /// `first`, then each path of `second` it does not hold yet, compared by scalars.
    private static func merged(_ first: [String], _ second: [String]) -> [String] {
        second.reduce(into: first) { merged, path in
            if !merged.contains(where: { $0.unicodeScalars.elementsEqual(path.unicodeScalars) }) {
                merged.append(path)
            }
        }
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
