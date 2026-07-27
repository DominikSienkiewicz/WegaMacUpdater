import Foundation

/// OBS-02 — one item's trip through update → validation → rollback, in a form that
/// survives a relaunch.
///
/// `ItemUpdateVerdict` already answers this for a *live* run, but it is an in-memory
/// enum that dies with the process: after a restart nothing in the app can say what the
/// last unattended round did, which is exactly the question a bug report has to answer.
/// This is its durable projection — deliberately narrower than the enum, because the
/// journal is written to be exported, and an exported record may carry no path, no
/// account name and no free-form tool output.
public struct UpdateJournalItem: Codable, Equatable, Sendable {
    /// Whether the package manager reported the install itself as done.
    public enum Phase: String, Codable, Sendable {
        /// The item cleared every phase it had to clear.
        case succeeded
        /// The package manager refused or errored — nothing was replaced.
        case executionFailed
        /// Installed, but the post-upgrade rescan could not confirm it.
        case unconfirmed
        /// Installed, and the rescan still reports it as outdated.
        case stillOutdated
        /// The new version failed validation and the previous one was restored.
        case rolledBack
        /// The new version failed validation and could **not** be restored.
        case rollbackFailed
        /// The publisher's Team ID changed — the upgrade is suspect whatever else happened.
        case publisherChanged
        /// The publisher changed and the previous trusted version was restored.
        case publisherChangedAndRolledBack
        /// The installed app already differed from the trusted baseline; no upgrade ran.
        case blockedBeforeUpgrade
    }

    /// The cask token / package name — never a filesystem path.
    public let name: String
    /// `cask`, `mas`, `npm`, `manual` — the source that owned the item.
    public let kind: String
    public let phase: Phase
    /// True when the item genuinely ended up on the new version.
    public let upgraded: Bool
    /// True when a rollback was attempted, whether or not it worked.
    public let rolledBack: Bool
    /// True when the publisher's Team ID changed. The Team IDs themselves are not
    /// recorded — the fact is the diagnostic; the values are the user's install identity.
    public let publisherChanged: Bool

    public init(
        name: String,
        kind: String,
        phase: Phase,
        upgraded: Bool,
        rolledBack: Bool,
        publisherChanged: Bool
    ) {
        self.name = name
        self.kind = kind
        self.phase = phase
        self.upgraded = upgraded
        self.rolledBack = rolledBack
        self.publisherChanged = publisherChanged
    }
}

/// One upgrade run, as remembered after it finished.
public struct UpdateJournalEntry: Codable, Equatable, Sendable {
    public enum Trigger: String, Codable, Sendable {
        /// Started from the window by the user.
        case manual
        /// An unattended background round.
        case background
    }

    public let finishedAt: Date
    public let trigger: Trigger
    public let items: [UpdateJournalItem]
    /// Whether the run hit macOS's App Management refusal — a run-level condition, not
    /// an item-level one.
    public let needsAppManagementPermission: Bool

    public init(
        finishedAt: Date,
        trigger: Trigger,
        items: [UpdateJournalItem],
        needsAppManagementPermission: Bool = false
    ) {
        self.finishedAt = finishedAt
        self.trigger = trigger
        self.items = items
        self.needsAppManagementPermission = needsAppManagementPermission
    }

    public var upgradedCount: Int { items.filter(\.upgraded).count }
    public var rollbackCount: Int { items.filter(\.rolledBack).count }
}

extension UpdateJournalEntry {
    /// Projects a finished run onto the durable record. The mapping is total: every
    /// `ItemUpdateVerdict` has exactly one phase, so a verdict added later fails to
    /// compile here rather than silently exporting as "succeeded".
    public init(summary: UpdateRunSummary, trigger: Trigger, finishedAt: Date) {
        self.init(
            finishedAt: finishedAt,
            trigger: trigger,
            items: summary.items.map(UpdateJournalItem.init(outcome:)),
            needsAppManagementPermission: summary.needsAppManagementPermission
        )
    }
}

extension UpdateJournalItem {
    init(outcome: ItemUpdateOutcome) {
        let phase = Phase(verdict: outcome.verdict)
        self.init(
            name: outcome.name,
            kind: String(describing: outcome.kind),
            phase: phase,
            upgraded: outcome.verdict.upgraded,
            rolledBack: phase.involvedRollback,
            publisherChanged: phase.involvedPublisherChange
        )
    }
}

extension UpdateJournalItem.Phase {
    init(verdict: ItemUpdateVerdict) {
        switch verdict {
        case .succeeded:                              self = .succeeded
        case .publisherChanged:                       self = .publisherChanged
        case .publisherChangedAndRolledBack:          self = .publisherChangedAndRolledBack
        case .publisherMismatchBeforeUpgrade:         self = .blockedBeforeUpgrade
        case .notVerified:                            self = .unconfirmed
        case .stillOutdated:                          self = .stillOutdated
        case .rolledBack:                             self = .rolledBack
        case .executionFailed:                        self = .executionFailed
        case .executionFailedAfterRollback:           self = .rolledBack
        case .executionFailedAfterPublisherRollback:  self = .publisherChangedAndRolledBack
        case .executionFailedWithPublisherChange:     self = .publisherChanged
        case .rollbackFailed:                         self = .rollbackFailed
        }
    }

    var involvedRollback: Bool {
        switch self {
        case .rolledBack, .rollbackFailed, .publisherChangedAndRolledBack: return true
        case .succeeded, .executionFailed, .unconfirmed, .stillOutdated,
             .publisherChanged, .blockedBeforeUpgrade: return false
        }
    }

    var involvedPublisherChange: Bool {
        switch self {
        case .publisherChanged, .publisherChangedAndRolledBack, .blockedBeforeUpgrade: return true
        case .succeeded, .executionFailed, .unconfirmed, .stillOutdated,
             .rolledBack, .rollbackFailed: return false
        }
    }
}

/// Where the journal's bytes live. Injectable so the pure trimming/decoding rules can be
/// exercised without touching the user's Application Support directory.
public protocol UpdateJournalStorage: Sendable {
    func read() -> Data?
    func write(_ data: Data) throws
}

/// OBS-02 — a bounded, append-only history of upgrade runs.
///
/// Bounded on purpose: an unbounded ledger of every run a machine ever performed is a
/// profile of the user's software habits, and none of it helps diagnose a failure that
/// happened this week. Only the most recent ``capacity`` runs are kept.
public struct UpdateRunJournal: Sendable {
    /// How many runs are retained. Enough to cover a couple of weeks of daily unattended
    /// rounds, small enough that the file stays a few kilobytes.
    public static let capacity = 40

    private let storage: UpdateJournalStorage

    public init(storage: UpdateJournalStorage) {
        self.storage = storage
    }

    public init(fileURL: URL = UpdateRunJournal.defaultFileURL) {
        self.init(storage: FileUpdateJournalStorage(fileURL: fileURL))
    }

    /// `~/Library/Application Support/WegaMacUpdater/update-history.json`, alongside the
    /// scan snapshot it complements.
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("WegaMacUpdater", isDirectory: true)
            .appendingPathComponent("update-history.json")
    }

    /// Every remembered run, oldest first. Fail-soft: an unreadable or corrupt journal
    /// reads as empty rather than throwing — a broken history may never block an export.
    public func entries() -> [UpdateJournalEntry] {
        guard let data = storage.read() else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([UpdateJournalEntry].self, from: data)) ?? []
    }

    /// Appends one run and trims the history back to ``capacity``.
    @discardableResult
    public func record(_ entry: UpdateJournalEntry) -> [UpdateJournalEntry] {
        let trimmed = Self.trimmed(entries() + [entry])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(trimmed) {
            try? storage.write(data)
        }
        return trimmed
    }

    static func trimmed(_ entries: [UpdateJournalEntry]) -> [UpdateJournalEntry] {
        entries.count <= capacity ? entries : Array(entries.suffix(capacity))
    }
}

/// SEC-09 permissions, applied to the journal for the same reason they are applied to the
/// log: it records what the machine installed, so it is owner-readable and nothing else.
struct FileUpdateJournalStorage: UpdateJournalStorage {
    let fileURL: URL

    func read() -> Data? { try? Data(contentsOf: fileURL) }

    func write(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path
        )
    }
}
