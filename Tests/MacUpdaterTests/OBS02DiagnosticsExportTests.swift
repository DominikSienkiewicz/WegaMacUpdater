import Foundation
import Testing
@testable import MacUpdaterCore

/// OBS-02 — the diagnostics bundle: it must carry everything a bug report needs, and it
/// must carry nothing that identifies the machine it came from.
///
/// The second half is the one that matters most. A diagnostics bundle is the only artefact
/// Wega produces that deliberately *leaves* the user's Mac, so "it is redacted" cannot be a
/// property of the code path that happened to be exercised — it is asserted here against
/// the finished archive **bytes**, with a snapshot whose every field is a piece of bait.
@Suite("OBS-02 diagnostics export")
struct OBS02DiagnosticsExportTests {

    // MARK: - Fixtures

    private static let referenceDate = Date(timeIntervalSince1970: 1_785_000_000)

    /// A snapshot with realistic, benign values — used for the completeness assertions.
    private func plainSnapshot(
        history: [UpdateJournalEntry] = [],
        logFiles: [DiagnosticsSnapshot.LogFile] = []
    ) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            generatedAt: Self.referenceDate,
            appVersion: "1.4.2",
            appBuild: "482",
            bundleIdentifier: "com.wega.macupdater",
            osVersion: "Version 26.1 (Build 26A123)",
            architecture: "arm64",
            processorCount: 12,
            managers: [
                .init(name: "Homebrew", version: "Homebrew 4.6.1", detected: true),
                .init(name: "mas-cli", version: "2.1.0", detected: true),
                .init(name: "npm", version: nil, detected: false),
            ],
            helper: .init(
                status: "enabled",
                expectedVersion: "2",
                reportedVersion: "2",
                teamIDConfigured: true
            ),
            schedule: .init(
                interval: "daily",
                lastCheck: Self.referenceDate.addingTimeInterval(-3600),
                nextCheck: Self.referenceDate.addingTimeInterval(82_800),
                lastCheckFailed: false,
                launchAtLogin: true,
                backgroundUpdatesEnabled: true
            ),
            lastScanAt: Self.referenceDate.addingTimeInterval(-3600),
            lastScanComplete: false,
            sourceResults: [
                .init(source: "Homebrew", outcome: "succeeded", error: nil),
                .init(source: "Mac App Store", outcome: "failed", error: "mas exited with 1"),
                .init(source: "npm", outcome: "not installed", error: nil),
            ],
            freeDiskBytes: 42 * 1024 * 1024 * 1024,
            signatures: [
                .init(subject: "Wega bundle", verdict: "signed by the expected Team ID"),
                .init(subject: "cask visual-studio-code", verdict: "held on the previous version — rollback"),
            ],
            appManagementPermission: "granted",
            history: history,
            logFiles: logFiles,
            logWriteFailureCount: 0
        )
    }

    private func journalEntry() -> UpdateJournalEntry {
        UpdateJournalEntry(
            finishedAt: Self.referenceDate.addingTimeInterval(-7200),
            trigger: .background,
            items: [
                UpdateJournalItem(name: "iterm2", kind: "cask", phase: .succeeded,
                                  upgraded: true, rolledBack: false, publisherChanged: false),
                UpdateJournalItem(name: "rectangle", kind: "cask", phase: .rolledBack,
                                  upgraded: false, rolledBack: true, publisherChanged: false),
                UpdateJournalItem(name: "some-app", kind: "cask", phase: .rollbackFailed,
                                  upgraded: false, rolledBack: true, publisherChanged: false),
            ],
            needsAppManagementPermission: true
        )
    }

    // MARK: - Completeness (the card's "Proponowana zmiana" list)

    @Test("The bundle carries both log files, including the rotated wega.log.1")
    func carriesBothLogFiles() {
        let snapshot = plainSnapshot(logFiles: [
            .init(name: "wega.log", contents: "2026-07-27T10:00:00Z [INFO] [App] current\n"),
            .init(name: "wega.log.1", contents: "2026-07-20T10:00:00Z [INFO] [App] rotated\n"),
        ])
        let names = DiagnosticsArchive.entryNames(inZip: DiagnosticsBundle.zipData(snapshot))

        #expect(names.contains("logs/wega.log"))
        #expect(names.contains("logs/wega.log.1"), "the rotated log is the half nothing else reads back")
        #expect(names.contains(DiagnosticsBundle.reportEntryName))
        #expect(names.contains(DiagnosticsBundle.historyEntryName))
    }

    @Test("The report states every environment fact the card enumerates")
    func reportCoversEveryRequiredFact() {
        let report = DiagnosticsBundle.report(plainSnapshot(history: [journalEntry()]), redact: { $0 })

        // App and system version.
        #expect(report.contains("Version: 1.4.2"))
        #expect(report.contains("Build: 482"))
        #expect(report.contains("Version 26.1 (Build 26A123)"))
        // Detected managers.
        #expect(report.contains("Homebrew: Homebrew 4.6.1"))
        #expect(report.contains("mas-cli: 2.1.0"))
        #expect(report.contains("npm: not detected"))
        // Helper status and version.
        #expect(report.contains("Status: enabled"))
        #expect(report.contains("Expected version: 2"))
        #expect(report.contains("Reported version: 2"))
        // Schedule status.
        #expect(report.contains("Check interval: daily"))
        #expect(report.contains("Unattended updates: yes"))
        // Per-source results.
        #expect(report.contains("Mac App Store: failed — mas exited with 1"))
        #expect(report.contains("npm: not installed"))
        // Free space.
        #expect(report.contains("Free disk space: 43008 MB"))
        // Signature state.
        #expect(report.contains("Wega bundle: signed by the expected Team ID"))
        #expect(report.contains("cask visual-studio-code: held on the previous version — rollback"))
        // History is present and pointed at.
        #expect(report.contains("Recorded runs: 1"))
    }

    @Test("The history file spells out update → validation → rollback per item")
    func historyRecordsEveryPhase() {
        let history = DiagnosticsBundle.history(plainSnapshot(history: [journalEntry()]), redact: { $0 })

        #expect(history.contains("background"))
        #expect(history.contains("cask · iterm2: phase=succeeded upgraded=true"))
        #expect(history.contains("cask · rectangle: phase=rolledBack upgraded=false rolledBack=true"))
        #expect(history.contains("cask · some-app: phase=rollbackFailed upgraded=false rolledBack=true"))
        #expect(history.contains("Blocked by a missing App Management permission."))
    }

    @Test("An empty history says so instead of producing an empty file")
    func emptyHistoryIsExplicit() {
        let history = DiagnosticsBundle.history(plainSnapshot(), redact: { $0 })
        #expect(history.contains("No runs recorded"))
    }

    // MARK: - Redaction (the reason this feature is allowed to exist)

    /// A snapshot in which every free-text field carries something that must never leave
    /// the machine. The assertion is made against the archive's raw bytes, so a field that
    /// skipped redaction cannot hide behind the API that produced it.
    private func baitedSnapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            generatedAt: Self.referenceDate,
            appVersion: "1.4.2",
            appBuild: "482",
            bundleIdentifier: "com.wega.macupdater",
            osVersion: "Version 26.1",
            architecture: "arm64",
            processorCount: 8,
            managers: [
                .init(name: "Homebrew", version: "installed at /Users/alicja/homebrew/bin/brew", detected: true),
            ],
            helper: .init(
                status: "enabled",
                expectedVersion: "2",
                reportedVersion: "reported from /Users/alicja/Library/PrivilegedHelperTools/x",
                teamIDConfigured: true
            ),
            schedule: .init(
                interval: "daily",
                lastCheck: nil,
                nextCheck: nil,
                lastCheckFailed: false,
                launchAtLogin: false,
                backgroundUpdatesEnabled: false
            ),
            lastScanAt: nil,
            lastScanComplete: false,
            sourceResults: [
                .init(source: "Homebrew", outcome: "failed",
                      error: "GET https://api.example.com/v1/casks?token=ghp_AAAABBBBCCCCDDDDEEEEFFFF0000 failed"),
                .init(source: "npm", outcome: "failed",
                      error: "npm ERR! reported to alicja.nowak@example.com by Authorization: Bearer abcdef1234567890"),
            ],
            freeDiskBytes: 1024 * 1024 * 1024,
            signatures: [
                .init(subject: "cask foo", verdict: "restored from /Users/alicja/Library/Caches/wega/foo"),
            ],
            appManagementPermission: "granted",
            history: [UpdateJournalEntry(
                finishedAt: Self.referenceDate,
                trigger: .manual,
                items: [UpdateJournalItem(name: "/Users/alicja/Applications/Foo.app", kind: "cask",
                                          phase: .succeeded, upgraded: true,
                                          rolledBack: false, publisherChanged: false)]
            )],
            logFiles: [.init(
                name: "wega.log",
                contents: """
                2026-07-27T10:00:00Z [INFO] [App] Skanuję /Users/alicja/Applications/Foo.app
                2026-07-27T10:00:01Z [ERROR] [Network] GET https://x.example/api?api_key=sk-abcdefghijklmnopqrstuvwxyz012345
                2026-07-27T10:00:02Z [INFO] [App] kontakt: alicja.nowak@example.com
                2026-07-27T10:00:03Z [INFO] [Helper] Authorization: Basic YWxpY2phOnNlY3JldA==
                2026-07-27T10:00:04Z [INFO] [App] password=hunter2 zapisane
                """
            )],
            logWriteFailureCount: 3
        )
    }

    /// The single most important test in this suite: nothing sensitive survives into the
    /// bytes the user is about to hand to a stranger.
    @Test("No path, credential or e-mail address survives into the archive bytes")
    func archiveBytesCarryNoSecrets() throws {
        let data = DiagnosticsBundle.zipData(baitedSnapshot())
        let text = try #require(String(data: data, encoding: .isoLatin1))

        for leak in [
            "/Users/alicja",
            "alicja.nowak@example.com",
            "ghp_AAAABBBBCCCCDDDDEEEEFFFF0000",
            "sk-abcdefghijklmnopqrstuvwxyz012345",
            "Bearer abcdef1234567890",
            "YWxpY2phOnNlY3JldA==",
            "hunter2",
        ] {
            #expect(!text.contains(leak), "the diagnostics archive leaked: \(leak)")
        }
    }

    @Test("Redaction leaves the diagnostic signal behind, not just holes")
    func redactionKeepsTheDiagnosis() {
        let report = DiagnosticsBundle.report(baitedSnapshot(), redact: { LogRedaction.redactForExport($0) })

        #expect(report.contains("[path]"))
        #expect(report.contains("Failed log writes: 3"))
        #expect(report.contains("Homebrew: failed"), "the failure itself must survive redaction")
    }

    @Test("Account names are removed even where no slash gives them away")
    func accountNamesAreRemoved() {
        let out = LogRedaction.redactForExport(
            "sudo: alicja is not in the sudoers file (Alicja Nowak)",
            userNames: ["alicja", "Alicja Nowak"]
        )
        #expect(!out.lowercased().contains("alicja"))
        #expect(out.contains("[user]"))
        #expect(out.contains("sudoers file"), "the rest of the message must survive")
    }

    @Test("A short or empty account name is left alone rather than shredding the text")
    func shortAccountNamesAreNotScrubbed() {
        let out = LogRedaction.redactForExport("ok, an admin action", userNames: ["ok", ""])
        #expect(out == "ok, an admin action")
    }

    @Test("Ordinary diagnostic prose is unchanged by the export redaction")
    func ordinaryProseSurvives() {
        let message = "GitHub · TestApp: błąd odpowiedzi lub parsowania"
        #expect(LogRedaction.redactForExport(message, userNames: ["zzzz"]) == message)
    }

    @Test(
        "Credentials are redacted wherever they appear",
        arguments: [
            "Authorization: Bearer abcdef1234567890",
            "api_key=sk-abcdefghijklmnopqrstuvwxyz012345",
            "token: ghp_AAAABBBBCCCCDDDDEEEEFFFF0000",
            "aws AKIAIOSFODNN7EXAMPLE key",
            "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "kontakt: ala@example.com",
        ]
    )
    func credentialsAreRedacted(_ message: String) {
        let out = LogRedaction.redact(message)
        #expect(out.contains("[secret]") || out.contains("[email]"), "not redacted: \(out)")
    }

    // MARK: - Archive format

    @Test("The archive is a well-formed zip: signatures, CRC and a central directory")
    func archiveIsWellFormedZip() {
        let entries = [
            DiagnosticsArchiveEntry(name: "a.txt", text: "hello"),
            DiagnosticsArchiveEntry(name: "dir/b.txt", text: "world"),
        ]
        let data = DiagnosticsArchive.zip(entries, modifiedAt: Self.referenceDate)

        #expect(Array(data.prefix(4)) == [0x50, 0x4b, 0x03, 0x04], "must start with a local file header")
        #expect(DiagnosticsArchive.entryNames(inZip: data) == ["a.txt", "dir/b.txt"])
        // The canonical CRC-32 of "hello" — a wrong table or seed makes every archive
        // open as corrupt on somebody else's machine, which a name check would not catch.
        #expect(DiagnosticsArchive.crc32(Data("hello".utf8)) == 0x3610_a686)
    }

    @Test("The same snapshot always produces the same bytes")
    func archiveIsDeterministic() {
        let snapshot = plainSnapshot(logFiles: [.init(name: "wega.log", contents: "x\n")])
        #expect(DiagnosticsBundle.zipData(snapshot) == DiagnosticsBundle.zipData(snapshot))
    }

    @Test("The suggested file name is sortable and carries no account name")
    func suggestedFileNameIsNeutral() {
        let name = DiagnosticsBundle.suggestedFileName(at: Date(timeIntervalSince1970: 0))
        #expect(name == "wega-diagnostics-1970-01-01-000000.zip")
    }
}

/// OBS-02 — the durable half: an upgrade run has to still be describable after the process
/// that performed it is gone, because that is when the bug report gets written.
@Suite("OBS-02 update run journal")
struct OBS02UpdateRunJournalTests {

    private final class MemoryStorage: UpdateJournalStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?

        func read() -> Data? {
            lock.lock(); defer { lock.unlock() }
            return data
        }

        func write(_ newData: Data) throws {
            lock.lock(); defer { lock.unlock() }
            data = newData
        }
    }

    private func entry(_ offset: TimeInterval) -> UpdateJournalEntry {
        UpdateJournalEntry(
            finishedAt: Date(timeIntervalSince1970: 1_785_000_000 + offset),
            trigger: .manual,
            items: []
        )
    }

    @Test("A recorded run survives a round-trip through storage")
    func roundTrips() {
        let journal = UpdateRunJournal(storage: MemoryStorage())
        journal.record(entry(0))
        journal.record(entry(60))

        #expect(journal.entries().count == 2)
        #expect(journal.entries().first == entry(0))
    }

    @Test("The journal is bounded — an unbounded install history is a profile, not a diagnostic")
    func trimsToCapacity() {
        let journal = UpdateRunJournal(storage: MemoryStorage())
        for index in 0..<(UpdateRunJournal.capacity + 5) {
            journal.record(entry(TimeInterval(index)))
        }
        let entries = journal.entries()

        #expect(entries.count == UpdateRunJournal.capacity)
        #expect(entries.first == entry(5), "the oldest runs are the ones dropped")
    }

    @Test("A corrupt journal reads as empty rather than blocking an export")
    func corruptJournalIsFailSoft() throws {
        let storage = MemoryStorage()
        try storage.write(Data("not json".utf8))
        #expect(UpdateRunJournal(storage: storage).entries().isEmpty)
    }

    private struct PhaseExpectation {
        let verdict: ItemUpdateVerdict
        let phase: UpdateJournalItem.Phase
        let rolledBack: Bool
        let publisherChanged: Bool
    }

    @Test("Every live verdict projects onto a durable phase")
    func verdictsProjectOntoPhases() {
        let cases: [PhaseExpectation] = [
            .init(verdict: .succeeded, phase: .succeeded, rolledBack: false, publisherChanged: false),
            .init(verdict: .executionFailed, phase: .executionFailed, rolledBack: false, publisherChanged: false),
            .init(verdict: .notVerified, phase: .unconfirmed, rolledBack: false, publisherChanged: false),
            .init(verdict: .stillOutdated, phase: .stillOutdated, rolledBack: false, publisherChanged: false),
            .init(verdict: .rolledBack, phase: .rolledBack, rolledBack: true, publisherChanged: false),
            .init(verdict: .rollbackFailed, phase: .rollbackFailed, rolledBack: true, publisherChanged: false),
            .init(verdict: .executionFailedAfterRollback, phase: .rolledBack,
                  rolledBack: true, publisherChanged: false),
            .init(verdict: .publisherChanged(old: "A", new: "B"), phase: .publisherChanged,
                  rolledBack: false, publisherChanged: true),
            .init(verdict: .publisherChangedAndRolledBack(old: "A", new: "B"),
                  phase: .publisherChangedAndRolledBack, rolledBack: true, publisherChanged: true),
            .init(verdict: .publisherMismatchBeforeUpgrade(old: "A", current: "B"),
                  phase: .blockedBeforeUpgrade, rolledBack: false, publisherChanged: true),
        ]

        for expectation in cases {
            let item = UpdateJournalItem(outcome: ItemUpdateOutcome(
                key: "cask:x", name: "x", kind: .cask, verdict: expectation.verdict
            ))
            #expect(item.phase == expectation.phase, "\(expectation.verdict)")
            #expect(item.rolledBack == expectation.rolledBack, "\(expectation.verdict)")
            #expect(item.publisherChanged == expectation.publisherChanged, "\(expectation.verdict)")
            #expect(item.upgraded == expectation.verdict.upgraded, "\(expectation.verdict)")
        }
    }

    @Test("The exported record carries no Team ID values, only the fact that one changed")
    func teamIDValuesAreNotJournalled() throws {
        let entry = UpdateJournalEntry(
            summary: UpdateRunSummary(
                items: [ItemUpdateOutcome(key: "cask:x", name: "x", kind: .cask,
                                          verdict: .publisherChanged(old: "AAAA111111", new: "BBBB222222"))],
                diagnostics: ["brew said something with /Users/alicja in it"],
                needsSudoPassword: false
            ),
            trigger: .background,
            finishedAt: Date(timeIntervalSince1970: 1_785_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(String(data: try encoder.encode([entry]), encoding: .utf8))

        #expect(!json.contains("AAAA111111"))
        #expect(!json.contains("BBBB222222"))
        #expect(!json.contains("alicja"), "verbatim tool output is not journalled")
        #expect(json.contains("publisherChanged"))
    }
}
