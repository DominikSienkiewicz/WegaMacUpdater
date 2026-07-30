import Foundation
import AppKit
import MacUpdaterCore

/// OBS-02 — the app-side half of the diagnostics export: it reads the running system into
/// a ``DiagnosticsSnapshot`` and hands the resulting bytes to a save panel.
///
/// Everything that decides *what the bundle says* and *what it is allowed to say* lives in
/// `MacUpdaterCore` (`DiagnosticsBundle`, `LogRedaction`, `DiagnosticsArchive`). This type
/// only gathers and writes, so the guarantees the card cares about — completeness and
/// redaction — are unit-testable without a window.
///
/// The bundle never leaves by itself. There is no upload, no share sheet and no default
/// destination: the user picks a location in `NSSavePanel` every time, and the file is
/// written exactly there.
@MainActor
final class DiagnosticsExportController: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var lastError: String?
    /// The file the user last saved, so the UI can offer "reveal in Finder" instead of
    /// making them go looking for it.
    @Published private(set) var lastExportURL: URL?

    private let journal = UpdateRunJournal()

    /// Builds the bundle and asks the user where to put it. Returns silently when the
    /// save panel is cancelled — a cancelled export is not an error.
    func export() async {
        guard !isExporting else { return }
        isExporting = true
        lastError = nil
        defer { isExporting = false }

        let snapshot = await snapshot()
        let data = DiagnosticsBundle.zipData(snapshot)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = DiagnosticsBundle.suggestedFileName(at: snapshot.generatedAt)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = tr("Paczka jest redagowana — ścieżki, tokeny i nazwy użytkownika są zastąpione znacznikami.")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
            lastExportURL = url
            WegaLog.info(.app, "Wyeksportowano paczkę diagnostyczną (\(data.count) B).")
        } catch {
            lastError = error.localizedDescription
            WegaLog.error(.app, "Eksport paczki diagnostycznej nie powiódł się: \(error.localizedDescription)")
        }
    }

    func revealLastExport() {
        guard let url = lastExportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Gathering

    func snapshot() async -> DiagnosticsSnapshot {
        let now = Date()
        let agent = MenuBarAgent.shared
        let scan = ScanResultStore().load()
        let helperVersion = try? await PrivilegedHelperClient.shared.helperVersion()
        let brewVersion = await Self.toolVersion(locator: { BinaryLocator().locateBrew() }, arguments: ["--version"])
        let masVersion = await Self.toolVersion(locator: { BinaryLocator().locateMas() }, arguments: ["version"])
        let npmDetected = await NpmLocator().locate() != nil

        return DiagnosticsSnapshot(
            generatedAt: now,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppMetadata.version,
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? AppMetadata.bundleIdentifier,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture(),
            processorCount: ProcessInfo.processInfo.processorCount,
            managers: [
                .init(name: "Homebrew", version: brewVersion, detected: brewVersion != nil),
                .init(name: "mas-cli", version: masVersion, detected: masVersion != nil),
                .init(name: "npm", version: nil, detected: npmDetected),
            ],
            helper: .init(
                status: Self.helperStatusLabel(PrivilegedHelperClient.shared.status),
                expectedVersion: WegaHelper.version,
                reportedVersion: helperVersion,
                teamIDConfigured: WegaHelper.isTeamIDConfigured
            ),
            schedule: .init(
                interval: agent.interval.rawValue,
                lastCheck: agent.lastCheck,
                nextCheck: agent.interval.seconds.map {
                    UpdateSchedule.nextCheckDate(lastCheck: agent.lastCheck, interval: $0, now: now)
                },
                lastCheckFailed: agent.lastCheckFailed,
                launchAtLogin: LoginItemService.shared.isEnabled,
                backgroundUpdatesEnabled: !BackgroundUpdateOptInStore.shared.tokens.isEmpty
            ),
            lastScanAt: scan?.scannedAt,
            lastScanComplete: scan?.isComplete ?? false,
            sourceResults: Self.sourceResults(scan?.sources),
            freeDiskBytes: DiskResourceProbe.availableBytes(),
            signatures: Self.signatures(),
            appManagementPermission: String(describing: AppManagementPermissionProbe.liveStatus()),
            history: journal.entries(),
            logFiles: Self.logFiles(),
            logWriteFailureCount: LogStore.shared.writeFailureCount
        )
    }

    /// Both log files, including the rotated `wega.log.1` — which nothing in the app has
    /// read back until now, so half of every long-running session's history was invisible
    /// to a bug report.
    static func logFiles() -> [DiagnosticsSnapshot.LogFile] {
        let directory = LogStore.shared.logFileURL.deletingLastPathComponent()
        return ["wega.log", "wega.log.1"].compactMap { name in
            guard let contents = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            else { return nil }
            return DiagnosticsSnapshot.LogFile(name: name, contents: contents)
        }
    }

    static func sourceResults(_ reports: ScanSourceReports?) -> [DiagnosticsSnapshot.SourceResult] {
        guard let reports else { return [] }
        let named: [(String, ScanSourceReport?)] = [
            ("Homebrew metadata", reports.brewMetadata),
            ("Homebrew", reports.brew),
            ("Mac App Store", reports.mas),
            ("npm", reports.npm),
            ("manual checkers", reports.manual),
        ]
        return named.compactMap { name, report in
            guard let report else { return nil }
            switch report.outcome {
            case .succeeded:
                return .init(source: name, outcome: "succeeded", error: nil)
            case .notInstalled:
                return .init(source: name, outcome: "not installed", error: nil)
            case .failed(let reason):
                return .init(source: name, outcome: "failed", error: report.error ?? reason)
            }
        }
    }

    /// The signature picture: whether this build is signed by the Team ID it expects, plus
    /// every cask currently held on a rolled-back version and why. Team ID *values* of the
    /// user's other apps are deliberately not exported — the verdict is the diagnostic.
    static func signatures() -> [DiagnosticsSnapshot.SignatureRecord] {
        var records: [DiagnosticsSnapshot.SignatureRecord] = []
        let ownTeamID = CodeSignatureVerifier.teamID(ofAppAt: Bundle.main.bundleURL)
        let verdict: String
        switch (ownTeamID, WegaHelper.isTeamIDConfigured) {
        case (nil, _):                                       verdict = "unsigned or unreadable"
        case (let teamID?, true) where teamID == WegaHelper.teamIdentifier: verdict = "signed by the expected Team ID"
        case (_?, true):                                     verdict = "signed by an unexpected Team ID"
        case (_?, false):                                    verdict = "signed; no expected Team ID configured in this build"
        }
        records.append(.init(subject: "Wega bundle", verdict: verdict))

        let ledger = CaskRollbackLedger.shared
        for token in ledger.rolledBackTokens().sorted() {
            let reason = ledger.reason(forToken: token)?.rawValue ?? "unknown"
            records.append(.init(subject: "cask \(token)", verdict: "held on the previous version — \(reason)"))
        }
        return records
    }

    static func helperStatusLabel(_ status: PrivilegedHelperClient.Status) -> String {
        switch status {
        case .notRegistered:    return "not registered"
        case .requiresApproval: return "requires approval"
        case .enabled:          return "enabled"
        case .notFound:         return "not found"
        case .unknown:          return "unknown"
        }
    }

    static func architecture() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &info.machine) { rawBytes -> String in
            guard let base = rawBytes.baseAddress else { return "unknown" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    nonisolated static func toolVersion(
        locator: @Sendable () -> URL?,
        arguments: [String]
    ) async -> String? {
        guard let url = locator(),
              let result = try? await ProcessRunner().run(ProcessRequest(
                  executableURL: url,
                  arguments: arguments,
                  environment: HomebrewEnvironment.environment,
                  inheritParentEnvironment: false,
                  // REL-12 — `.quick`, not a bare deadline: `timeout: 5` left the inactivity
                  // limit inheriting `.query`'s 180 s, which the deadline could never reach.
                  timeouts: .quick
              ))
        else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (text.split(separator: "\n").first.map(String.init) ?? text)
    }
}
