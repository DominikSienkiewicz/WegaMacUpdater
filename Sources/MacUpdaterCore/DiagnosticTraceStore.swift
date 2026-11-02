import Foundation
import WegaHelperKit

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let timestamp: String
    public let sequence: UInt64
    public let runID: UUID
    public let processID: UUID?
    public let event: String
    public let fields: [String: String]
    public let output: String?
}

public final class DiagnosticTraceStore: @unchecked Sendable {
    public struct Limits: Sendable {
        public let maxFileBytes: Int
        public let maxTotalBytes: Int
        public let maxFiles: Int
        public let retentionDays: Int

        public init(maxFileBytes: Int = 8 * 1024 * 1024, maxTotalBytes: Int = 64 * 1024 * 1024,
                    maxFiles: Int = 50, retentionDays: Int = 14) {
            self.maxFileBytes = maxFileBytes
            self.maxTotalBytes = maxTotalBytes
            self.maxFiles = maxFiles
            self.retentionDays = retentionDays
        }
    }

    public static let shared = DiagnosticTraceStore(directory: LogStore.defaultDirectory.appendingPathComponent("traces"))
    public let directory: URL
    public let limits: Limits
    private let lock = NSLock()
    private var runs: [UUID: RunState] = [:]
    private var failedWrites = 0
    private var failedReads = 0
    private var prunedFiles = 0

    private struct RunState {
        var sequence: UInt64 = 0
        var bytes = 0
        var omittedOutputBytes = 0
        var omittedEvents = 0
        var announcedTruncation = false
        var finished = false
    }

    public var writeFailureCount: Int { lock.withLock { failedWrites } }

    public init(directory: URL, limits: Limits = .init()) {
        self.directory = directory
        self.limits = limits
    }

    public func events(runID: UUID) -> [DiagnosticEvent] {
        lock.withLock { readLocked(fileURL(runID)).events }
    }

    public func exportFiles() -> [DiagnosticsSnapshot.LogFile] {
        lock.withLock { exportLocked() }
    }

    func begin(runID: UUID, fields: [String: String]) {
        lock.withLock {
            pruneLocked(reservingFiles: 1)
            runs[runID] = RunState()
            appendLocked(runID: runID, event: "trace.started", fields: fields, processID: nil, output: nil)
        }
    }

    func append(runID: UUID, event: String, fields: [String: String], processID: UUID?, output: String?) {
        lock.withLock {
            appendLocked(runID: runID, event: event, fields: fields, processID: processID, output: output)
        }
    }

    func finish(runID: UUID, elapsedSeconds: Double) {
        lock.withLock {
            guard let state = runs[runID], !state.finished else { return }
            appendLocked(runID: runID, event: "trace.finished", fields: [
                "elapsed_seconds": String(elapsedSeconds),
                "omitted_output_bytes": String(state.omittedOutputBytes),
                "omitted_events": String(state.omittedEvents),
                "meaning": "diagnostic scope ended; inspect stage outcomes",
            ], processID: nil, output: nil, terminal: true)
            runs[runID]?.finished = true
            pruneLocked()
        }
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("trace-\(id.uuidString).jsonl")
    }

    private func appendLocked(
        runID: UUID, event: String, fields: [String: String], processID: UUID?, output: String?, terminal: Bool = false
    ) {
        guard var state = runs[runID], !state.finished else { return }
        let redactedFields = fields.mapValues { bounded(LogRedaction.redact($0)) }
        let entry = DiagnosticEvent(
            schemaVersion: 1, timestamp: Date().ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            sequence: state.sequence + 1, runID: runID, processID: processID,
            event: String(event.prefix(128)), fields: redactedFields, output: output.map(LogRedaction.redact)
        )
        guard let data = encoded(entry) else { failedWrites += 1; return }
        let fileBudget = max(2048, limits.maxFileBytes)
        let ceiling = output != nil ? fileBudget * 3 / 4 : terminal ? fileBudget : fileBudget - 1024
        if state.bytes + data.count > ceiling {
            state.omittedOutputBytes += output?.utf8.count ?? 0
            state.omittedEvents += 1
            let announce = !state.announcedTruncation
            state.announcedTruncation = true
            runs[runID] = state
            if announce {
                appendLocked(runID: runID, event: "trace.truncated", fields: [
                    "reason": "per_run_byte_limit", "max_file_bytes": String(fileBudget),
                    "meaning": "later output may be omitted; terminal counters describe the loss",
                ], processID: nil, output: nil)
            }
            return
        }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let url = fileURL(runID)
            if !manager.fileExists(atPath: url.path) {
                guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    failedWrites += 1
                    return
                }
            }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
            if terminal || event == "trace.started" { try file.synchronize() }
            state.sequence += 1
            state.bytes += data.count
            runs[runID] = state
        } catch {
            failedWrites += 1
        }
    }

    private func bounded(_ value: String) -> String {
        guard value.utf8.count > 16_384 else { return value }
        return String(value.prefix(4096)) + " [field truncated]"
    }

    private func encoded(_ event: DiagnosticEvent) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(event) else { return nil }
        data.append(0x0A)
        return data
    }

    private struct ReadResult {
        var events: [DiagnosticEvent] = []
        var invalidRecords = 0
        var unreadable = false
    }

    private func readLocked(_ url: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReadResult() }
        do {
            let data = try Data(contentsOf: url)
            var result = ReadResult()
            let decoder = JSONDecoder()
            for line in data.split(separator: 0x0A) {
                if let event = try? decoder.decode(DiagnosticEvent.self, from: Data(line)) {
                    result.events.append(event)
                } else {
                    result.invalidRecords += 1
                }
            }
            return result
        } catch {
            failedReads += 1
            return ReadResult(unreadable: true)
        }
    }

    private struct TraceFile {
        let url: URL
        let bytes: Int
        let modified: Date
    }

    private func filesLocked() -> [TraceFile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            )
            return try urls.filter { $0.lastPathComponent.hasPrefix("trace-") && $0.pathExtension == "jsonl" }.compactMap {
                let values = try $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true else { return nil }
                return TraceFile(url: $0, bytes: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
            }.sorted { $0.modified < $1.modified }
        } catch {
            failedReads += 1
            return []
        }
    }

    private func pruneLocked(reservingFiles: Int = 0) {
        let files = filesLocked()
        var total = files.reduce(0) { $0 + $1.bytes }
        var count = files.count + reservingFiles
        let cutoff = Date().addingTimeInterval(-Double(max(1, limits.retentionDays)) * 86_400)
        for file in files {
            let id = UUID(uuidString: file.url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "trace-", with: ""))
            if let id, let state = runs[id], !state.finished { continue }
            guard file.modified < cutoff || count > max(1, limits.maxFiles) || total > limits.maxTotalBytes else { continue }
            do {
                try FileManager.default.removeItem(at: file.url)
                total -= file.bytes
                count -= 1
                prunedFiles += 1
                if let id { runs.removeValue(forKey: id) }
            } catch {
                failedWrites += 1
            }
        }
    }

    private func exportLocked() -> [DiagnosticsSnapshot.LogFile] {
        pruneLocked()
        var logs: [DiagnosticsSnapshot.LogFile] = []
        var traces: [[String: Any]] = []
        let userNames = LogRedaction.currentUserNames()
        for file in filesLocked() {
            let read = readLocked(file.url)
            var data = Data()
            for event in read.events {
                let redacted = DiagnosticEvent(
                    schemaVersion: event.schemaVersion, timestamp: event.timestamp, sequence: event.sequence,
                    runID: event.runID, processID: event.processID, event: event.event,
                    fields: event.fields.mapValues { LogRedaction.redactForExport($0, userNames: userNames) },
                    output: event.output.map { LogRedaction.redactForExport($0, userNames: userNames) }
                )
                if let line = encoded(redacted) { data.append(line) }
            }
            logs.append(.init(name: file.url.lastPathComponent, contents: String(decoding: data, as: UTF8.self)))
            let finished = read.events.last?.event == "trace.finished"
            let id = read.events.first?.runID
            traces.append([
                "file": file.url.lastPathComponent, "run_id": id?.uuidString ?? "unknown",
                "state": finished ? "finished" : id.flatMap { runs[$0] }.map { !$0.finished } == true ? "active" : "unfinished",
                "cause": "unknown", "records": read.events.count, "invalid_records": read.invalidRecords,
                "unreadable": read.unreadable,
                "output_truncated": read.events.contains { $0.event == "trace.truncated" || $0.event == "process.output_truncated" },
            ])
        }
        let manifest: [String: Any] = [
            "schema_version": 1, "traces": traces,
            "write_failures": failedWrites, "read_failures": failedReads, "pruned_files_this_session": prunedFiles,
            "retention_days": limits.retentionDays, "max_files": limits.maxFiles,
            "max_file_bytes": limits.maxFileBytes, "max_total_bytes": limits.maxTotalBytes,
            "redaction": "credentials and paths before storage; user names also removed for export",
            "scope": "Wega operations only; no external app logs, environment values, HTTP bodies or headers",
            "unfinished_meaning": "no terminal event; cause unknown, not proof of a crash",
            "retention_note": "active runs are retained; global limits are enforced between operations and at export",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            logs.append(.init(name: "trace-manifest.json", contents: String(decoding: data, as: UTF8.self)))
        }
        return logs
    }
}

public final class DiagnosticRun: Sendable {
    public let id = UUID()
    private let store: DiagnosticTraceStore
    private let started = ContinuousClock.now

    public init(trigger: String, subjects: [String], store: DiagnosticTraceStore = .shared) {
        self.store = store
        store.begin(runID: id, fields: [
            "trigger": trigger, "subjects": subjects.joined(separator: ", "),
            "app_version": AppMetadata.version,
            "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? AppMetadata.version,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": Self.architecture,
        ])
    }

    public func record(_ event: String, fields: [String: String] = [:], processID: UUID? = nil, output: String? = nil) {
        store.append(runID: id, event: event, fields: fields, processID: processID, output: output)
    }

    public func finish() {
        let duration = started.duration(to: .now)
        let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        store.finish(runID: id, elapsedSeconds: elapsed)
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

public enum UpdateDiagnostics {
    @TaskLocal public static var current: DiagnosticRun?

    public static func record(_ event: String, fields: [String: String] = [:]) {
        current?.record(event, fields: fields)
    }
}
