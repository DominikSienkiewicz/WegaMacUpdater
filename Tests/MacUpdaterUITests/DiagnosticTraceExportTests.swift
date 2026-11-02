import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Persistent diagnostic trace export")
@MainActor
struct DiagnosticTraceExportTests {
    @Test func snapshotArtifactsKeepTraceManifestAlongsideOrdinaryLogsAndCountFailures() {
        let traces: [DiagnosticsSnapshot.LogFile] = [
            .init(name: "trace-example.jsonl", contents: "{\"event\":\"run.started\"}\n"),
            .init(name: "trace-manifest.json", contents: "{\"incomplete\":1}"),
        ]
        let artifacts = DiagnosticsExportController.artifacts(
            history: [], logs: [.init(name: "wega.log", contents: "ordinary log")],
            logWriteFailures: 2, traceLogs: traces, traceWriteFailures: 3
        )

        #expect(artifacts.logFiles.map(\.name) == ["wega.log", "trace-example.jsonl", "trace-manifest.json"])
        #expect(artifacts.logFiles.suffix(2) == traces[...])
        #expect(artifacts.logWriteFailureCount == 5)
    }

    @Test func persistedRunAndManifestReachTheRedactedZip() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticTraceStore(directory: directory)
        let run = DiagnosticRun(trigger: "test", subjects: ["example"], store: store)
        UpdateDiagnostics.$current.withValue(run) {
            UpdateDiagnostics.record("test.observation", fields: ["detail": "token=private-export-token"])
        }
        run.finish()
        let artifacts = DiagnosticsExportController.artifacts(
            history: [], logs: [], logWriteFailures: 0,
            traceLogs: store.exportFiles(), traceWriteFailures: store.writeFailureCount
        )
        let snapshot = DiagnosticsSnapshot(
            runtime: .init(generatedAt: Date(), appVersion: "1", appBuild: "1", bundleIdentifier: "test.wega",
                           osVersion: "test", architecture: "arm64", processorCount: 1),
            managers: [],
            helper: .init(status: "test", expectedVersion: "1", reportedVersion: nil, teamIDConfigured: false),
            schedule: .init(interval: "off", lastCheck: nil, nextCheck: nil, lastCheckFailed: false,
                            launchAtLogin: false, backgroundUpdatesEnabled: false),
            scan: .init(lastScanAt: nil, complete: false, sourceResults: []),
            system: .init(freeDiskBytes: nil, signatures: [], appManagementPermission: "unknown"),
            artifacts: artifacts
        )

        let zip = DiagnosticsBundle.zipData(snapshot)
        let names = DiagnosticsArchive.entryNames(inZip: zip)
        #expect(names.contains { $0.lowercased() == "logs/trace-\(run.id.uuidString.lowercased()).jsonl" })
        #expect(names.contains("logs/trace-manifest.json"))
        let contents = String(decoding: zip, as: UTF8.self)
        #expect(contents.contains("test.observation"))
        #expect(!contents.contains("private-export-token"))
    }
}
