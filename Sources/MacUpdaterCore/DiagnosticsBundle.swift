import Foundation

/// OBS-02 — turns a ``DiagnosticsSnapshot`` into the redacted archive a user attaches to
/// a bug report.
///
/// Two properties matter more than anything else here, and both are enforced structurally
/// rather than by convention:
///
/// 1. **Everything is redacted.** No value reaches an archive entry except through
///    ``redact``. There is no "raw" path through this type, so a field added later cannot
///    forget to be scrubbed — it is redacted by the only mechanism that emits it.
/// 2. **Nothing leaves by itself.** This type produces `Data`. It never writes a file,
///    never opens a panel and never talks to the network; where the bytes go is the user's
///    decision, made in a save panel, every time.
///
/// The report is written in English with stable labels, for the same reason
/// ``InventoryExport`` is: a bundle is data interchange between a user and a maintainer,
/// and it must read identically whatever language the app is running in.
public enum DiagnosticsBundle {

    /// Applied to every value that reaches the archive.
    public typealias Redactor = @Sendable (String) -> String

    public static let reportEntryName = "report.txt"
    public static let historyEntryName = "update-history.txt"
    public static let logDirectoryName = "logs"

    /// Builds the archive's entries — the report, the run history, and every log file
    /// the snapshot carried (including the rotated `wega.log.1`, which nothing else in
    /// the app has ever read back).
    public static func entries(
        _ snapshot: DiagnosticsSnapshot,
        redact: @escaping Redactor = { LogRedaction.redactForExport($0) }
    ) -> [DiagnosticsArchiveEntry] {
        var entries: [DiagnosticsArchiveEntry] = [
            DiagnosticsArchiveEntry(name: reportEntryName, text: report(snapshot, redact: redact)),
            DiagnosticsArchiveEntry(name: historyEntryName, text: history(snapshot, redact: redact)),
        ]
        // Each log file is redacted in ONE call, whole, never split by line.
        // `LogRedaction`'s `pemBlock` pattern matches "-----BEGIN … PRIVATE KEY-----"
        // through "-----END … PRIVATE KEY-----" and needs both markers in the same pass to
        // fire; a failed `git`, `ssh` or `gpg` subprocess can write a whole key to stderr
        // and from there into `wega.log`, so redacting line by line would never present the
        // block to that pattern and the key would leave the machine verbatim.
        for file in snapshot.logFiles {
            entries.append(DiagnosticsArchiveEntry(
                name: "\(logDirectoryName)/\(file.name)",
                text: redact(file.contents)
            ))
        }
        return entries
    }

    /// The finished archive.
    public static func zipData(
        _ snapshot: DiagnosticsSnapshot,
        redact: @escaping Redactor = { LogRedaction.redactForExport($0) }
    ) -> Data {
        DiagnosticsArchive.zip(entries(snapshot, redact: redact), modifiedAt: snapshot.generatedAt)
    }

    /// `wega-diagnostics-2026-07-27-142530.zip` — sortable, collision-free within a
    /// second, and carrying no account name.
    public static func suggestedFileName(at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d-%02d-%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return "wega-diagnostics-\(stamp).zip"
    }

    // MARK: - Report

    static func report(_ snapshot: DiagnosticsSnapshot, redact: @escaping Redactor) -> String {
        var out = Section(redact: redact)

        out.title("Wega Mac Updater — diagnostics report")
        out.line("Generated: \(iso(snapshot.generatedAt))")
        out.line("This bundle is redacted: filesystem paths, URL query strings, credentials,")
        out.line("e-mail addresses and account names are replaced with placeholders.")

        out.header("Application")
        out.field("Version", snapshot.appVersion)
        out.field("Build", snapshot.appBuild)
        out.field("Bundle identifier", snapshot.bundleIdentifier)

        out.header("System")
        out.field("macOS", snapshot.osVersion)
        out.field("Architecture", snapshot.architecture)
        out.field("CPU cores", String(snapshot.processorCount))
        out.field("Free disk space", snapshot.freeDiskBytes.map(megabytes) ?? "unknown")
        out.field("App Management permission", snapshot.appManagementPermission)

        out.header("Package managers")
        if snapshot.managers.isEmpty {
            out.line("(none detected)")
        }
        for manager in snapshot.managers {
            let detail = manager.detected ? (manager.version ?? "detected, version unknown") : "not detected"
            out.field(manager.name, detail)
        }

        out.header("Privileged helper")
        out.field("Status", snapshot.helper.status)
        out.field("Expected version", snapshot.helper.expectedVersion)
        out.field("Reported version", snapshot.helper.reportedVersion ?? "unavailable")
        out.field("Team ID configured", yesNo(snapshot.helper.teamIDConfigured))

        out.header("Schedule")
        out.field("Check interval", snapshot.schedule.interval)
        out.field("Last check", snapshot.schedule.lastCheck.map(iso) ?? "never")
        out.field("Last check failed", yesNo(snapshot.schedule.lastCheckFailed))
        out.field("Next check", snapshot.schedule.nextCheck.map(iso) ?? "not scheduled")
        out.field("Launch at login", yesNo(snapshot.schedule.launchAtLogin))
        out.field("Unattended updates", yesNo(snapshot.schedule.backgroundUpdatesEnabled))

        out.header("Last scan")
        out.field("Scanned at", snapshot.lastScanAt.map(iso) ?? "never")
        out.field("Complete", yesNo(snapshot.lastScanComplete))
        if snapshot.sourceResults.isEmpty {
            out.line("(no per-source results recorded)")
        }
        for result in snapshot.sourceResults {
            let error = result.error.map { " — \($0)" } ?? ""
            out.field(result.source, result.outcome + error)
        }

        out.header("Signatures")
        if snapshot.signatures.isEmpty {
            out.line("(no signature verdicts recorded)")
        }
        for record in snapshot.signatures {
            out.field(record.subject, record.verdict)
        }

        out.header("Logs")
        out.field("Failed log writes", String(snapshot.logWriteFailureCount))
        if snapshot.logFiles.isEmpty {
            out.line("(no log files found)")
        }
        for file in snapshot.logFiles {
            out.field(file.name, "\(lineCount(file.contents)) lines — \(logDirectoryName)/\(file.name)")
        }

        out.header("Update history")
        out.field("Recorded runs", String(snapshot.history.count))
        out.line("Full update → validation → rollback history: \(historyEntryName)")

        return out.rendered
    }

    // MARK: - History

    static func history(_ snapshot: DiagnosticsSnapshot, redact: @escaping Redactor) -> String {
        var out = Section(redact: redact)
        out.title("Update → validation → rollback history")
        out.line("Most recent \(UpdateRunJournal.capacity) runs at most, oldest first.")

        if snapshot.history.isEmpty {
            out.header("No runs recorded")
            out.line("Wega has not completed an upgrade run since this history was introduced.")
            return out.rendered
        }

        for entry in snapshot.history {
            out.header("\(iso(entry.finishedAt)) — \(entry.trigger.rawValue)")
            out.field("Items", String(entry.items.count))
            out.field("Upgraded", String(entry.upgradedCount))
            out.field("Rolled back", String(entry.rollbackCount))
            if entry.needsAppManagementPermission {
                out.line("Blocked by a missing App Management permission.")
            }
            for item in entry.items {
                var flags: [String] = ["phase=\(item.phase.rawValue)"]
                flags.append("upgraded=\(item.upgraded)")
                if item.rolledBack { flags.append("rolledBack=true") }
                if item.publisherChanged { flags.append("publisherChanged=true") }
                out.field("  \(item.kind) · \(item.name)", flags.joined(separator: " "))
            }
        }
        return out.rendered
    }

    // MARK: - Helpers

    private static func lineCount(_ contents: String) -> Int {
        contents.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func megabytes(_ bytes: Int64) -> String {
        "\(bytes / (1024 * 1024)) MB"
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// The single gate every emitted character passes through. `field` and `line` redact;
    /// there is no third way to add text, so no field can be written unredacted.
    private struct Section {
        let redact: Redactor
        private var lines: [String] = []

        init(redact: @escaping Redactor) { self.redact = redact }

        mutating func title(_ text: String) {
            lines.append(redact(text))
            lines.append(String(repeating: "=", count: text.count))
        }

        mutating func header(_ text: String) {
            lines.append("")
            lines.append("## \(redact(text))")
        }

        mutating func line(_ text: String) {
            lines.append(redact(text))
        }

        mutating func field(_ label: String, _ value: String) {
            lines.append("\(redact(label)): \(redact(value))")
        }

        var rendered: String { lines.joined(separator: "\n") + "\n" }
    }
}
