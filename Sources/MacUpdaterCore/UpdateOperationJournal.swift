import Foundation

/// LT-01 — the durable, per-phase journal of one update operation.
///
/// Before this, the snapshot → canary → rollback chain lived entirely in memory and in a
/// *predictable* temp directory (`/tmp/wega-rollback/<token>.app`), and a healthy upgrade
/// deleted its snapshot the moment the canary passed. A crash, a kill or a power loss
/// mid-upgrade left no record that an operation had ever started: nothing could recognize
/// the interruption, nothing cleaned up the orphaned clones, and there was no way to undo
/// an update that turned out to break the user's workflow a day later.
///
/// Every mutating upgrade now runs inside an operation with its **own unique directory**
/// (`update-operations/<uuid>/`), writes each phase transition to disk *before* acting on
/// it, and keeps committed snapshots for ``UpdateOperationStore/retentionInterval`` so a
/// manual "Cofnij aktualizację" stays possible after the fact. At launch,
/// `UpdateOperationRecovery` (app layer) walks the unfinished operations and settles them.
public enum UpdateOperationPhase: String, Codable, Equatable, Sendable, CaseIterable {
    /// The item was written into the journal before any mutation.
    case planned
    /// The pre-upgrade clone exists inside the operation directory.
    case snapshotted
    /// The package manager is (or may be) replacing the bundle.
    case installing
    /// The post-install canary passed; the commit has not been recorded yet.
    case verified
    /// Terminal: the new version stayed and the snapshot is kept for the retention window.
    case committed
    /// Terminal: the previous version was restored (by the canary, by recovery, or by the
    /// user's own "Cofnij aktualizację").
    case rolledBack
    /// Terminal: settled without a lasting mutation — either brew never ran for this item,
    /// or recovery found the disk untouched.
    case aborted

    public var isTerminal: Bool {
        switch self {
        case .committed, .rolledBack, .aborted: return true
        case .planned, .snapshotted, .installing, .verified: return false
        }
    }
}

/// What started the operation. Kept for the journal reader: a background round that
/// crashed is the one a recovery report must be loudest about.
public enum UpdateOperationTrigger: String, Codable, Equatable, Sendable {
    /// The window's "Zaktualizuj…" run.
    case manual
    /// An unattended background round.
    case background
    /// A `brew install --cask --force` adoption ("Aktualizuj przez Brew" / migration).
    case adoption
}

/// One phase transition, timestamped. The full history is kept so a post-crash reading
/// can say *how far* the operation got, not just where it stopped.
public struct UpdateOperationPhaseEntry: Codable, Equatable, Sendable {
    public let phase: UpdateOperationPhase
    public let at: Date

    public init(phase: UpdateOperationPhase, at: Date) {
        self.phase = phase
        self.at = at
    }
}

/// One cask inside an operation. `snapshotName` is the clone's directory name *relative
/// to the operation's `snapshots/` subdirectory* — never an absolute path, so the journal
/// stays valid if the whole tree is moved, and holds nothing sensitive.
public struct UpdateOperationItem: Codable, Equatable, Sendable, Identifiable {
    public let token: String
    /// Absolute path of the installed `.app` the snapshot was taken from / will be
    /// restored over. Recorded so recovery and the manual undo never have to re-derive
    /// the target from a brew query that may no longer answer after a crash.
    public let appPath: String
    /// The bundle identifier read before the mutation, so a restore never lands on a
    /// different app than the one that was cloned.
    public let bundleIdentifier: String?
    /// `CFBundleShortVersionString` before the mutation — what a manual undo pins.
    public let preUpgradeVersion: String?
    public internal(set) var snapshotName: String?
    public internal(set) var phase: UpdateOperationPhase
    /// True when the rollback was the user's own choice ("Cofnij aktualizację") rather
    /// than a canary/recovery decision — the two tell very different stories in a log.
    public internal(set) var rolledBackByUser: Bool
    /// How many times crash recovery already tried to settle this item. One retry is
    /// honest; an unbounded one would re-attempt a failing restore — and re-notify about
    /// it — on every single launch.
    public internal(set) var recoveryAttempts: Int
    public internal(set) var history: [UpdateOperationPhaseEntry]

    public var id: String { token }

    public init(
        token: String,
        appPath: String,
        bundleIdentifier: String?,
        preUpgradeVersion: String?,
        phase: UpdateOperationPhase = .planned,
        history: [UpdateOperationPhaseEntry] = []
    ) {
        self.token = token
        self.appPath = appPath
        self.bundleIdentifier = bundleIdentifier
        self.preUpgradeVersion = preUpgradeVersion
        self.snapshotName = nil
        self.phase = phase
        self.rolledBackByUser = false
        self.recoveryAttempts = 0
        self.history = history
    }
}

/// One update operation, as persisted in `<operation dir>/operation.json`.
public struct UpdateOperation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let trigger: UpdateOperationTrigger
    public internal(set) var items: [UpdateOperationItem]

    public init(id: UUID, startedAt: Date, trigger: UpdateOperationTrigger, items: [UpdateOperationItem] = []) {
        self.id = id
        self.startedAt = startedAt
        self.trigger = trigger
        self.items = items
    }

    public var isFinished: Bool { items.allSatisfy { $0.phase.isTerminal } }
}

/// An update the user can still undo: the operation committed it, the snapshot is on
/// disk, and the retention window has not closed.
public struct UndoableUpdate: Equatable, Sendable, Identifiable {
    public let operationID: UUID
    public let token: String
    public let appPath: String
    /// The version the undo would bring back (read before the upgrade).
    public let restoredVersion: String?
    public let updatedAt: Date
    public let expiresAt: Date

    public var id: String { "\(operationID.uuidString):\(token)" }

    public init(
        operationID: UUID,
        token: String,
        appPath: String,
        restoredVersion: String?,
        updatedAt: Date,
        expiresAt: Date
    ) {
        self.operationID = operationID
        self.token = token
        self.appPath = appPath
        self.restoredVersion = restoredVersion
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }
}

/// The pure half of crash recovery: given where an item's journal stopped, what should
/// the app layer do about it? Pure so every branch is unit-testable without a filesystem
/// full of fake apps — the runner (`UpdateOperationRecovery`, app layer) only executes.
public enum UpdateOperationRecoveryPlan {
    public enum Action: Equatable, Sendable {
        /// `planned` / `snapshotted`: the journal never reached `installing`, so brew was
        /// never started — the disk is untouched and the snapshot is redundant.
        case abortWithoutMutation
        /// `verified`: the canary had already passed; only the commit record is missing.
        case commitVerified
        /// `installing`: brew may have replaced the bundle. The app layer must probe the
        /// disk (see ``InstallingProbe``) before settling.
        case probeInstalledApp
        /// Terminal phase: nothing to settle.
        case settle
    }

    public static func action(for phase: UpdateOperationPhase) -> Action {
        switch phase {
        case .planned, .snapshotted: return .abortWithoutMutation
        case .installing: return .probeInstalledApp
        case .verified: return .commitVerified
        case .committed, .rolledBack, .aborted: return .settle
        }
    }

    /// What the on-disk probe found for an item stuck in `installing`.
    public enum InstallingProbe: Equatable, Sendable {
        /// The recorded app path is gone — the replacement died mid-swap.
        case appMissing
        /// The app on disk still reports the pre-upgrade version: brew never finished.
        /// Nothing was mutated, so the snapshot is redundant.
        case untouched
        /// A different version is on disk: the upgrade went through but the operation
        /// died before validation. It needs the same canary chain any upgrade gets.
        case mutated
    }

    public static func installingProbe(
        appExists: Bool,
        installedVersion: String?,
        preUpgradeVersion: String?
    ) -> InstallingProbe {
        guard appExists else { return .appMissing }
        if let installed = installedVersion, let before = preUpgradeVersion,
           versionsEqual(installed, before) {
            return .untouched
        }
        return .mutated
    }
}

/// Owns the `update-operations/` tree: unique directory per operation, an atomically
/// rewritten `operation.json` after every phase transition, and the retention sweep.
///
/// Writes are *synchronous and immediate* on purpose — a phase that only exists in
/// memory is exactly what a crash erases. The files are a few hundred bytes, so the
/// cost of durability here is noise.
public final class UpdateOperationStore: @unchecked Sendable {
    public static let shared = UpdateOperationStore()

    /// How long a committed snapshot survives for a possible manual undo (LT-01:
    /// "retencja N dni"). A week covers "the weekend update broke my Monday" without
    /// turning Application Support into an app museum.
    public static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    private let rootDirectory: URL
    private let lock = NSLock()

    /// `rootDirectory` is injectable so tests run against a throwaway tree instead of
    /// the user's Application Support.
    public init(rootDirectory: URL = UpdateOperationStore.defaultRootDirectory) {
        self.rootDirectory = rootDirectory
    }

    /// `~/Library/Application Support/WegaMacUpdater/update-operations/`. **Not** the
    /// temp directory: `$TMPDIR` is reaped after three days, which would silently close
    /// the retention window the undo feature promises.
    public static var defaultRootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("WegaMacUpdater", isDirectory: true)
            .appendingPathComponent("update-operations", isDirectory: true)
    }

    /// Starts a new operation in its own unique directory and returns the session that
    /// records its phases.
    public func begin(trigger: UpdateOperationTrigger, now: Date = Date()) -> UpdateOperationSession {
        let operation = UpdateOperation(id: UUID(), startedAt: now, trigger: trigger)
        let session = UpdateOperationSession(store: self, operation: operation)
        persist(session.operation)
        return session
    }

    /// Every operation on disk, oldest first. Corrupt or unreadable journals are
    /// skipped — a broken file may never block an upgrade or recovery.
    public func operations() -> [UpdateOperation] {
        lock.lock(); defer { lock.unlock() }
        return loadAllOperations()
    }

    /// Updates the user can still undo right now: committed items whose snapshot is
    /// actually on disk, inside the retention window.
    public func undoableUpdates(now _: Date = Date()) -> [UndoableUpdate] {
        lock.lock(); defer { lock.unlock() }
        var result: [UndoableUpdate] = []
        for operation in loadAllOperations() {
            let committedAt = operation.items
                .flatMap(\.history)
                .filter { $0.phase == .committed }
                .map(\.at)
                .max() ?? operation.startedAt
            for item in operation.items where item.phase == .committed {
                guard let snapshotName = item.snapshotName,
                      FileManager.default.fileExists(
                        atPath: snapshotURL(operationID: operation.id, name: snapshotName).path
                      ) else { continue }
                let updatedAt = item.history.last(where: { $0.phase == .committed })?.at ?? committedAt
                result.append(UndoableUpdate(
                    operationID: operation.id,
                    token: item.token,
                    appPath: item.appPath,
                    restoredVersion: item.preUpgradeVersion,
                    updatedAt: updatedAt,
                    expiresAt: updatedAt.addingTimeInterval(Self.retentionInterval)
                ))
            }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Reopens the session for an operation that is already on disk — how crash recovery
    /// records its settlements through the same write path the live run used.
    public func resumeSession(operationID: UUID) -> UpdateOperationSession? {
        guard let operation = loadOperation(id: operationID) else { return nil }
        return UpdateOperationSession(store: self, operation: operation)
    }

    /// Loads one operation together with the recorded item, for the manual undo.
    public func operationAndItem(operationID: UUID, token: String) -> (UpdateOperation, UpdateOperationItem)? {
        lock.lock(); defer { lock.unlock() }
        guard let operation = loadOperationLocked(id: operationID),
              let item = operation.items.first(where: { $0.token == token }) else { return nil }
        return (operation, item)
    }

    /// Marks an item as rolled back by the user's own request. The snapshot itself is
    /// consumed by the restore (moved into place) before this is called.
    public func markUndoneByUser(operationID: UUID, token: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard var operation = loadOperationLocked(id: operationID),
              let index = operation.items.firstIndex(where: { $0.token == token }) else { return }
        Self.transition(&operation.items[index], to: .rolledBack, at: now)
        operation.items[index].rolledBackByUser = true
        persistLocked(operation)
    }

    /// The retention sweep, run at launch and after each operation: expire snapshots past
    /// the window, then remove operation directories that hold nothing restorable anymore
    /// (every item terminal, no snapshot left). An operation whose items are *not* all
    /// terminal is recovery's business, not the sweeper's — it is left untouched.
    ///
    /// The aging clock is the item's last recorded phase change, not the filesystem:
    /// journal timestamps are what the undo UI shows as the expiry, and the two must
    /// agree about when the window closes.
    @discardableResult
    public func pruneExpired(now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        var removed = 0
        for operation in loadAllOperations() {
            let directory = operationDirectory(id: operation.id)
            guard operation.isFinished else { continue }
            var snapshotsRemain = false
            for item in operation.items {
                guard let snapshotName = item.snapshotName else { continue }
                let url = snapshotURL(operationID: operation.id, name: snapshotName)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let lastPhaseAt = item.history.map(\.at).max() ?? operation.startedAt
                if now.timeIntervalSince(lastPhaseAt) > Self.retentionInterval {
                    try? FileManager.default.removeItem(at: url)
                    removed += 1
                } else {
                    snapshotsRemain = true
                }
            }
            if !snapshotsRemain {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        return removed
    }

    /// Removes the operation directory entirely — used when a blocked or aborted run
    /// leaves nothing worth retaining.
    public func removeOperation(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: operationDirectory(id: id))
    }

    // MARK: - Paths (also used by the session and the guard)

    public func operationDirectory(id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func snapshotsDirectory(operationID: UUID) -> URL {
        operationDirectory(id: operationID).appendingPathComponent("snapshots", isDirectory: true)
    }

    public func snapshotURL(operationID: UUID, name: String) -> URL {
        snapshotsDirectory(operationID: operationID).appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - Session write-through (called by UpdateOperationSession only)

    func persist(_ operation: UpdateOperation) {
        lock.lock(); defer { lock.unlock() }
        persistLocked(operation)
    }

    func loadOperation(id: UUID) -> UpdateOperation? {
        lock.lock(); defer { lock.unlock() }
        return loadOperationLocked(id: id)
    }

    // MARK: - Locked internals

    private func persistLocked(_ operation: UpdateOperation) {
        let directory = operationDirectory(id: operation.id)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(operation)
            let fileURL = directory.appendingPathComponent("operation.json")
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path
            )
        } catch {
            // A journal that cannot be written must never break the upgrade itself —
            // the in-memory chain still protects this run; the log says what was lost.
            WegaLog.error(.app, "LT-01: nie udało się zapisać journalu operacji: \(error.localizedDescription)")
        }
    }

    private func loadAllOperations() -> [UpdateOperation] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .compactMap { loadOperationLocked(url: $0) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func loadOperationLocked(id: UUID) -> UpdateOperation? {
        loadOperationLocked(url: operationDirectory(id: id))
    }

    private func loadOperationLocked(url: URL) -> UpdateOperation? {
        let fileURL = url.appendingPathComponent("operation.json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UpdateOperation.self, from: data)
    }

    /// One transition, appended to the item's history and stamped as its current phase.
    static func transition(_ item: inout UpdateOperationItem, to phase: UpdateOperationPhase, at: Date) {
        item.phase = phase
        item.history.append(UpdateOperationPhaseEntry(phase: phase, at: at))
    }
}

/// The live handle one upgrade flow holds onto. Every method records the transition and
/// flushes the journal synchronously, so the file on disk is never behind the mutation.
public final class UpdateOperationSession {
    public let store: UpdateOperationStore
    public private(set) var operation: UpdateOperation

    /// Where this operation's clones live — the guard snapshots straight into it.
    public var snapshotsDirectory: URL { store.snapshotsDirectory(operationID: operation.id) }

    /// The directory name a token's snapshot gets inside `snapshots/`. Cask tokens are
    /// already filesystem-safe (`[a-z0-9@+.-]`), but the name feeds a path a root helper
    /// may restore through — a surprising token must never become a path traversal.
    public static func snapshotDirectoryName(for token: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@+.-_"))
        let sanitized = String(token.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        // `.`/`..` are legal output of the filter above and still special to the filesystem.
        let safe = (sanitized.isEmpty || sanitized == "." || sanitized == "..") ? "snapshot" : sanitized
        return safe + ".app"
    }

    init(store: UpdateOperationStore, operation: UpdateOperation) {
        self.store = store
        self.operation = operation
    }

    /// `planned` — before *any* mutation. Also captures the facts a later restore must
    /// not have to re-derive: where the app lives, its bundle identifier and the version
    /// a manual undo would bring back.
    public func recordPlanned(tokens: [String], appPaths: [String: URL], now: Date = Date()) {
        for token in tokens {
            guard let appURL = appPaths[token],
                  !operation.items.contains(where: { $0.token == token }) else { continue }
            let info = Bundle(url: appURL)?.infoDictionary
            var item = UpdateOperationItem(
                token: token,
                appPath: appURL.path,
                bundleIdentifier: info?["CFBundleIdentifier"] as? String,
                preUpgradeVersion: info?["CFBundleShortVersionString"] as? String
            )
            UpdateOperationStore.transition(&item, to: .planned, at: now)
            operation.items.append(item)
        }
        store.persist(operation)
    }

    /// The snapshot for one token exists. `name` is relative to `snapshotsDirectory`.
    public func recordSnapshotted(token: String, snapshotName: String, now: Date = Date()) {
        mutate(token: token) { item in
            item.snapshotName = snapshotName
            UpdateOperationStore.transition(&item, to: .snapshotted, at: now)
        }
    }

    /// The package manager is about to run. From this line on, a crash means "the disk
    /// state is unknown" — which is exactly what recovery reads this phase as.
    public func recordInstalling(now: Date = Date()) {
        for index in operation.items.indices where operation.items[index].phase == .snapshotted {
            UpdateOperationStore.transition(&operation.items[index], to: .installing, at: now)
        }
        store.persist(operation)
    }

    /// The canary spoke for one item: `verified` is recorded first (the canary passed),
    /// then the terminal phase. A rollback verdict skips `verified` — the canary did
    /// *not* pass — and lands in `rolledBack`; a failed rollback leaves the item in
    /// `installing`, non-terminal, so recovery re-examines it at the next launch.
    public func recordVerdict(token: String, verdict: CaskValidationVerdict, now: Date = Date()) {
        mutate(token: token) { item in
            switch verdict {
            case .healthy:
                UpdateOperationStore.transition(&item, to: .verified, at: now)
                UpdateOperationStore.transition(&item, to: .committed, at: now)
            case .rolledBack, .publisherChangedAndRolledBack:
                UpdateOperationStore.transition(&item, to: .rolledBack, at: now)
            case .rollbackFailed, .publisherChanged:
                break
            }
        }
    }

    /// Every item that never reached a terminal phase is settled as `aborted` — used
    /// when a run stops before the package manager ever ran (blocked, interrupted at a
    /// boundary, preparation failed). Snapshots of an untouched disk restore nothing, so
    /// the caller removes the directory afterwards.
    public func abortUnfinished(now: Date = Date()) {
        var changed = false
        for index in operation.items.indices where !operation.items[index].phase.isTerminal {
            UpdateOperationStore.transition(&operation.items[index], to: .aborted, at: now)
            changed = true
        }
        if changed { store.persist(operation) }
    }

    /// Settles one item as `aborted` — recovery's verdict for an operation the journal
    /// proves never reached brew, or whose disk turned out untouched.
    public func markAborted(token: String, now: Date = Date()) {
        mutate(token: token) { item in
            UpdateOperationStore.transition(&item, to: .aborted, at: now)
        }
    }

    /// Settles one item as `committed` — recovery's verdict for an item whose canary had
    /// already passed (`verified`) when the process died.
    public func markCommitted(token: String, now: Date = Date()) {
        mutate(token: token) { item in
            UpdateOperationStore.transition(&item, to: .committed, at: now)
        }
    }

    /// Settles one item as `rolledBack` — recovery's own restore, where no canary ran.
    public func markRolledBack(token: String, now: Date = Date()) {
        mutate(token: token) { item in
            UpdateOperationStore.transition(&item, to: .rolledBack, at: now)
        }
    }

    /// Notes that crash recovery has now tried once to settle this item (see
    /// ``UpdateOperationItem/recoveryAttempts``).
    public func noteRecoveryAttempt(token: String, now _: Date = Date()) {
        mutate(token: token) { item in
            item.recoveryAttempts += 1
        }
    }

    private func mutate(token: String, _ body: (inout UpdateOperationItem) -> Void) {
        guard let index = operation.items.firstIndex(where: { $0.token == token }) else { return }
        body(&operation.items[index])
        store.persist(operation)
    }
}
