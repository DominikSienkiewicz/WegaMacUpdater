import Foundation
import Testing
@testable import MacUpdaterCore

/// OBS-02 — the diagnostics zip is the artefact that deliberately leaves the machine, so
/// what it carries out of a log file is the whole point of these tests.
@Suite("DiagnosticsBundle redaction")
struct DiagnosticsBundleRedactionTests {

    private static let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    /// Injected instead of the live account names, so the guarantee is verifiable on any
    /// machine rather than only on one whose login happens to appear in the fixture.
    private let redact: DiagnosticsBundle.Redactor = {
        LogRedaction.redactForExport($0, userNames: ["ala", "Ala Kowalska"])
    }

    private func snapshot(logFile contents: String) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            runtime: .init(generatedAt: Self.referenceDate, appVersion: "1.4.2", appBuild: "812",
                           bundleIdentifier: "com.wega.macupdater", osVersion: "26.1",
                           architecture: "arm64", processorCount: 12),
            managers: [],
            helper: .init(status: "enabled", expectedVersion: "2",
                          reportedVersion: "2", teamIDConfigured: true),
            schedule: .init(interval: "daily", lastCheck: nil, nextCheck: nil, lastCheckFailed: false,
                            launchAtLogin: false, backgroundUpdatesEnabled: false),
            scan: .init(lastScanAt: nil, complete: false, sourceResults: []),
            system: .init(freeDiskBytes: nil, signatures: [], appManagementPermission: "granted"),
            artifacts: .init(history: [],
                             logFiles: [.init(name: "wega.log", contents: contents)],
                             logWriteFailureCount: 0)
        )
    }

    private func exportedLog(_ contents: String) throws -> String {
        let entries = DiagnosticsBundle.entries(snapshot(logFile: contents), redact: redact)
        let name = "\(DiagnosticsBundle.logDirectoryName)/wega.log"
        return try #require(entries.first { $0.name == name }?.text)
    }

    /// A PEM key spans several lines, and `LogRedaction.pemBlock` needs the BEGIN and END
    /// markers in the *same* call to fire. `wega.log` can hold one since a failure detail
    /// writes raw `stderr` as continuation lines, so the export must hand the file to the
    /// redactor whole — splitting it per line guarantees the key survives verbatim into
    /// the zip.
    @Test func aMultiLinePEMKeyInALogFileCannotSurviveIntoTheBundle() throws {
        let key = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtz
        c2gtZWQyNTUxOQAAACBQ1n8FQ8ZK7t0aQ2mA0m0V3Uu3wq8bMdEjF2KfA9uYow
        -----END OPENSSH PRIVATE KEY-----
        """
        let indentedKey = key.components(separatedBy: "\n")
            .map { LogDetail.continuationPrefix + $0 }
            .joined(separator: "\n")
        let text = try exportedLog("""
        2026-08-20T10:11:12Z [ERROR] [Process] ssh-keygen exited 1
        \(LogDetail.continuationPrefix)command: ssh-keygen -y
        \(LogDetail.continuationPrefix)exit: 1
        \(LogDetail.continuationPrefix)\(LogDetail.outputMarker)
        \(indentedKey)
        2026-08-20T10:11:13Z [INFO] [App] koniec
        """)

        #expect(text.contains("-----BEGIN") == false)
        #expect(text.contains("-----END") == false)
        for line in key.components(separatedBy: "\n").dropFirst().dropLast() {
            #expect(text.contains(line) == false, "linia base64 klucza przetrwała: \(line)")
        }
        #expect(text.contains(LogRedaction.secretPlaceholder))
    }

    /// The line-bounded rules must keep working on a whole-file pass: every one of them is
    /// anchored on `\S` or a character class that stops at a newline, so redacting the file
    /// in one call may only ever remove *more*, never less.
    @Test func theOrdinaryPerLineRulesStillFire() throws {
        let text = try exportedLog("""
        2026-08-20T10:00:00Z [INFO] [App] Skanuję /Users/ala/Applications/Foo.app
        2026-08-20T10:00:01Z [ERROR] [Network] GET https://x.example/api?api_key=sk-abcdefghijklmnopqrstuvwxyz012345
        2026-08-20T10:00:02Z [INFO] [App] kontakt: ala.kowalska@example.com
        2026-08-20T10:00:03Z [INFO] [Helper] Authorization: Basic YWxpY2phOnNlY3JldA==
        """)

        #expect(text.contains("/Users/ala") == false)
        #expect(text.contains("sk-abcdefghijklmnopqrstuvwxyz012345") == false)
        #expect(text.contains("ala.kowalska@example.com") == false)
        #expect(text.contains("YWxpY2phOnNlY3JldA==") == false)
    }

    /// Line structure is what makes an exported log readable — the whole-file pass must not
    /// join lines together or drop the blank ones.
    @Test func theLineStructureOfTheFileIsPreserved() throws {
        let text = try exportedLog("2026-08-20T10:00:00Z [INFO] [App] a\n\n2026-08-20T10:00:01Z [INFO] [App] b\n")
        #expect(text.components(separatedBy: "\n").count == 4)
        #expect(text.hasSuffix("\n"))
    }
}
