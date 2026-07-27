import Foundation

/// LT-05 — the local, bounded home of the crash and hang reports MetricKit hands Wega about
/// itself.
///
/// Everything about this store is deliberately local. Wega has no crash-reporting endpoint,
/// and this type has no network code and no "submit" path: a diagnostic is data from the
/// user's machine, so it is written next to `wega.log` — same directory, same `0700`/`0600`
/// permissions — and stays there until the user copies it out or deletes it. The July 22
/// crash needed a report handed over by hand; this removes the *finding* of the report from
/// that job, not the user's decision to send it.
///
/// Retention is enforced on every write, in both directions: at most ``maxRecords`` reports,
/// none older than ``maxAge``. A diagnostic file that grows without bound is a liability, not
/// an asset — the last handful of crashes is what diagnoses a regression.
public final class CrashDiagnosticStore: @unchecked Sendable {
    public static let shared = CrashDiagnosticStore()

    public static let defaultMaxRecords = 20
    public static let defaultMaxAge: TimeInterval = 90 * 24 * 60 * 60

    private let directory: URL
    private let maxRecords: Int
    private let maxAge: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()

    /// Writes next to `wega.log`, which means the test-only redirect ``LogStore/defaultDirectory``
    /// applies here too: `swift test` can never touch the user's real diagnostics.
    public init(
        directory: URL = LogStore.defaultDirectory,
        maxRecords: Int = CrashDiagnosticStore.defaultMaxRecords,
        maxAge: TimeInterval = CrashDiagnosticStore.defaultMaxAge,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.maxRecords = maxRecords
        self.maxAge = maxAge
        self.now = now
    }

    public var fileURL: URL { directory.appendingPathComponent("crash-diagnostics.json") }

    /// Stored reports, newest first, already pruned by age.
    public func records() -> [CrashDiagnosticRecord] {
        lock.lock(); defer { lock.unlock() }
        return retained(loaded())
    }

    /// Folds newly delivered reports into the store and returns the ones that were genuinely
    /// new, so the caller can log or surface exactly those. Redelivery of a report already on
    /// disk is a no-op: MetricKit may hand the same diagnostic over more than once.
    @discardableResult
    public func ingest(_ incoming: [CrashDiagnosticRecord]) -> [CrashDiagnosticRecord] {
        lock.lock(); defer { lock.unlock() }
        let existing = loaded()
        var known = Set(existing.map(\.id))
        var added: [CrashDiagnosticRecord] = []
        for record in incoming where !known.contains(record.id) {
            known.insert(record.id)
            added.append(record)
        }
        guard !added.isEmpty else { return [] }
        persist(retained(existing + added))
        return added
    }

    /// Deletes every stored report and the file itself — the user's "forget this" button.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The whole store as the text a user copies out of Settings. Redacted by construction:
    /// every field was passed through ``LogRedaction`` when its record was built.
    public func reportText() -> String {
        let stored = records()
        guard !stored.isEmpty else { return "" }
        return stored.map(\.reportText).joined(separator: "\n\n")
    }

    // MARK: - Retention

    private func retained(_ records: [CrashDiagnosticRecord]) -> [CrashDiagnosticRecord] {
        let cutoff = now().addingTimeInterval(-maxAge)
        return records
            .filter { $0.occurredAt >= cutoff }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(maxRecords)
            .map { $0 }
    }

    // MARK: - Disk

    private func loaded() -> [CrashDiagnosticRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CrashDiagnosticRecord].self, from: data)) ?? []
    }

    private func persist(_ records: [CrashDiagnosticRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        do {
            try Self.ensureDirectory(directory)
            try Self.write(data, to: fileURL)
        } catch {
            WegaLog.warning(.app, "Nie udało się zapisać raportów awarii: \(error.localizedDescription)")
        }
    }

    /// SEC-09 — owner-only (`0700`), explicitly rather than at the mercy of the process
    /// `umask`, exactly as ``LogStore`` does for the log directory they share.
    private static func ensureDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: dir.path
        )
    }

    /// SEC-09 — the report file is `0600`. A crash report describes the user's machine; no
    /// other account on it gets to read one.
    private static func write(_ data: Data, to fileURL: URL) throws {
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path
        )
    }
}
