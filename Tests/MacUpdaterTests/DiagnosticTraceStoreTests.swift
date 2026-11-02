import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Persistent update diagnostics")
struct DiagnosticTraceStoreTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-trace-\(UUID())")
    }

    @Test func anUpdateCanBeReconstructedAfterOpeningTheStoreAgain() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticTraceStore(directory: root)
        let run = DiagnosticRun(trigger: "manual", subjects: ["discord"], store: store)
        let processID = UUID()
        run.record("process.started", fields: ["command": "brew upgrade --cask discord"], processID: processID)
        run.record("process.output", fields: ["stream": "stdout"], processID: processID, output: "Upgrading discord\n")
        run.record("validation.version", fields: ["before": "0.0.419", "after": "0.0.420"])
        run.finish()

        let reopened = DiagnosticTraceStore(directory: root)
        let events = reopened.events(runID: run.id)
        #expect(events.map(\.event) == ["trace.started", "process.started", "process.output", "validation.version", "trace.finished"])
        #expect(events.allSatisfy { $0.runID == run.id })
        #expect(events.map(\.sequence) == [1, 2, 3, 4, 5])
        #expect(events.first { $0.event == "process.output" }?.processID == processID)
        #expect(events.first { $0.event == "process.output" }?.output == "Upgrading discord\n")
        #expect(events.first?.fields["app_version"] != nil)
        #expect(events.first?.fields["os_version"] != nil)
        #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(try FileManager.default.attributesOfItem(atPath: #require(files.first).path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func anOutputLimitPreservesTheVerdictAndAnnouncesMissingBytes() {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = DiagnosticTraceStore.Limits(maxFileBytes: 8192, maxTotalBytes: 32768, maxFiles: 10, retentionDays: 14)
        let store = DiagnosticTraceStore(directory: root, limits: limits)
        let run = DiagnosticRun(trigger: "manual", subjects: ["docker-desktop"], store: store)
        for _ in 0..<20 { run.record("process.output", output: String(repeating: "x", count: 1024)) }
        run.record("validation.completed", fields: ["verdict": "notUpgraded"])
        run.finish()

        let events = store.events(runID: run.id)
        #expect(events.contains { $0.event == "trace.truncated" })
        #expect(events.contains { $0.fields["verdict"] == "notUpgraded" })
        #expect(events.last?.event == "trace.finished")
        #expect(Int(events.last?.fields["omitted_output_bytes"] ?? "0") ?? 0 > 0)
        #expect(store.exportFiles().contains { $0.name == "trace-manifest.json" })
    }

    @Test func exportDescribesAnUnfinishedRunWithoutInventingACrash() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DiagnosticTraceStore(directory: root)
        let run = DiagnosticRun(trigger: "background", subjects: ["docker-desktop"], store: first)
        run.record("install.started")
        let reopened = DiagnosticTraceStore(directory: root)
        let manifest = try #require(reopened.exportFiles().first { $0.name == "trace-manifest.json" })
        let json = try #require(JSONSerialization.jsonObject(with: Data(manifest.contents.utf8)) as? [String: Any])
        let traces = try #require(json["traces"] as? [[String: Any]])
        let entry = try #require(traces.first)
        #expect(entry["state"] as? String == "unfinished")
        #expect(entry["cause"] as? String == "unknown")
        #expect(entry["run_id"] as? String == run.id.uuidString)
    }

    @Test func retentionDropsOldFinishedRunsButPreservesTheActiveOne() {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = DiagnosticTraceStore.Limits(maxFileBytes: 8192, maxTotalBytes: 32768, maxFiles: 2, retentionDays: 14)
        let store = DiagnosticTraceStore(directory: root, limits: limits)
        let active = DiagnosticRun(trigger: "manual", subjects: ["docker-desktop"], store: store)
        let old = DiagnosticRun(trigger: "manual", subjects: ["discord"], store: store)
        old.finish()
        let newest = DiagnosticRun(trigger: "manual", subjects: ["slack"], store: store)
        newest.finish()
        #expect(!store.events(runID: active.id).isEmpty)
        #expect(store.events(runID: old.id).isEmpty)
        #expect(!store.events(runID: newest.id).isEmpty)
        active.finish()
    }

    @Test func sensitiveFactsAreRedactedBeforeStorageAndExport() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticTraceStore(directory: root)
        let run = DiagnosticRun(trigger: "manual", subjects: ["discord"], store: store)
        run.record("process.output", fields: ["command": "curl -H 'Authorization: Bearer extremely-secret-value'"],
                   output: "password=hunter2\n/Users/alice/private/file.txt\nalice@example.test")
        run.finish()
        let contents = try String(contentsOf: root.appendingPathComponent("trace-\(run.id.uuidString).jsonl"), encoding: .utf8)
        for secret in ["extremely-secret-value", "hunter2", "/Users/alice", "alice@example.test"] {
            #expect(!contents.contains(secret))
            #expect(store.exportFiles().allSatisfy { !$0.contents.contains(secret) })
        }
        #expect(contents.contains("process.output"))
    }

    @Test func aWriteFailureIsVisibleWithoutThrowingIntoTheUpdate() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        let store = DiagnosticTraceStore(directory: root)
        let run = DiagnosticRun(trigger: "manual", subjects: ["discord"], store: store)
        run.record("install.completed", fields: ["exit": "0"])
        run.finish()
        #expect(store.writeFailureCount > 0)
        #expect(store.exportFiles().contains { $0.contents.contains("write_failures") })
    }
}
