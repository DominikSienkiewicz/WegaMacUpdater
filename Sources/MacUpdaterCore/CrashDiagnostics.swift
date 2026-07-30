import Foundation

/// LT-05 — what kind of failure a MetricKit diagnostic describes.
///
/// Only the two kinds that answer "why did Wega die / freeze on this Mac?" are ingested.
/// MetricKit also delivers CPU- and disk-exception diagnostics and a daily *metric* payload
/// (usage, battery, launch times); those are behavioural telemetry rather than a crash
/// report, so they are dropped at the parser rather than stored and then filtered.
public enum CrashDiagnosticKind: String, Codable, Sendable, CaseIterable {
    case crash
    case hang
}

/// One symbolicatable stack frame: the binary it came from, that binary's build UUID and the
/// offset into its text segment.
///
/// Deliberately *not* the raw MetricKit frame: the runtime `address` (an ASLR-slid pointer,
/// useless without the slide) and `sampleCount` are dropped. What remains is exactly what
/// `atos -o <binary> -l 0 <offset>` needs to turn the frame into a symbol.
public struct CrashDiagnosticFrame: Codable, Equatable, Sendable {
    public let binaryName: String
    public let binaryUUID: String?
    public let offset: Int

    public init(binaryName: String, binaryUUID: String? = nil, offset: Int) {
        // LT-05/SEC-09: everything that reaches a stored report goes through the same
        // redaction as a log line. A binary name is normally a bare name, but MetricKit is a
        // system source we do not control, so it is treated as untrusted text like any other.
        self.binaryName = LogRedaction.redact(binaryName)
        self.binaryUUID = binaryUUID.map(LogRedaction.redact)
        self.offset = offset
    }

    /// `WegaMacUpdater +123456 (UUID)` — one line of the human-readable report.
    public var line: String {
        let uuidSuffix = binaryUUID.map { " (\($0))" } ?? ""
        return "\(binaryName) +\(offset)\(uuidSuffix)"
    }
}

/// LT-05 — one crash or hang of *this* app, reduced to the fields a developer needs to
/// diagnose it and stripped of everything that describes the person running it.
///
/// The record is what MetricKit's payload becomes after `CrashDiagnosticPayloadParser` is
/// done with it. Three classes of field present in the raw payload never make it this far:
///
///   * **Identity of the machine and its owner** — `regionFormat` (the user's locale),
///     `deviceType` (the Mac model) and the process `pid` are dropped. Architecture and OS
///     version are kept because a crash that only happens on one of them is a real bug
///     signal, and neither identifies a Mac.
///   * **Memory contents** — `virtualMemoryRegionInfo` is a dump of the faulting address's
///     neighbourhood and can quote heap data; it is dropped outright.
///   * **Anything that survives** is passed through ``LogRedaction`` on the way in, so a
///     filesystem path or URL query that MetricKit did put in a string cannot reach the
///     stored report with the user's home directory or a token still in it.
///
/// The record stays local. Nothing in Wega uploads it; ``reportText`` exists so the *user*
/// can copy a report and choose to send it.
public struct CrashDiagnosticRecord: Codable, Equatable, Identifiable, Sendable {
    public let kind: CrashDiagnosticKind
    public let occurredAt: Date
    public let appVersion: String?
    public let appBuildVersion: String?
    public let osVersion: String?
    public let platformArchitecture: String?
    public let signal: Int?
    public let exceptionType: Int?
    public let exceptionCode: Int?
    public let terminationReason: String?
    public let hangDurationSeconds: Double?
    public let frames: [CrashDiagnosticFrame]

    public init(
        kind: CrashDiagnosticKind,
        occurredAt: Date,
        appVersion: String? = nil,
        appBuildVersion: String? = nil,
        osVersion: String? = nil,
        platformArchitecture: String? = nil,
        signal: Int? = nil,
        exceptionType: Int? = nil,
        exceptionCode: Int? = nil,
        terminationReason: String? = nil,
        hangDurationSeconds: Double? = nil,
        frames: [CrashDiagnosticFrame] = []
    ) {
        self.kind = kind
        self.occurredAt = occurredAt
        self.appVersion = appVersion.map(LogRedaction.redact)
        self.appBuildVersion = appBuildVersion.map(LogRedaction.redact)
        self.osVersion = osVersion.map(LogRedaction.redact)
        self.platformArchitecture = platformArchitecture.map(LogRedaction.redact)
        self.signal = signal
        self.exceptionType = exceptionType
        self.exceptionCode = exceptionCode
        self.terminationReason = terminationReason.map(LogRedaction.redact)
        self.hangDurationSeconds = hangDurationSeconds
        self.frames = frames
    }

    /// Stable across re-deliveries of the same diagnostic: MetricKit can hand the same crash
    /// over twice (a fresh payload and again through the historical payloads), and the store
    /// deduplicates on this. Derived from the crash time plus the top of the stack rather than
    /// from a fresh UUID, which would make every redelivery look like a new crash.
    /// The digest is FNV-1a rather than `String.hashValue`: Swift seeds its hasher per
    /// process, so a `hashValue` would change on every relaunch and the same crash read back
    /// from disk would look like a new one.
    public var id: String {
        let stamp = Int(occurredAt.timeIntervalSince1970.rounded())
        let signature = frames.prefix(3).map(\.line).joined(separator: "|")
        return "\(kind.rawValue)-\(stamp)-\(Self.digest(of: signature))"
    }

    static func digest(of text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// One line, safe for the activity log: what happened, in which build, and why the
    /// process died. No stack, no counts — the detail lives in ``reportText``.
    public var headline: String {
        var parts: [String] = [kind == .crash ? "crash" : "hang"]
        if let appVersion { parts.append("Wega \(appVersion)") }
        if let osVersion { parts.append(osVersion) }
        if kind == .hang, let hangDurationSeconds {
            parts.append(String(format: "%.1f s", hangDurationSeconds))
        }
        if let terminationReason, !terminationReason.isEmpty {
            parts.append(terminationReason)
        } else if let signal {
            parts.append("signal \(signal)")
        }
        return parts.joined(separator: " · ")
    }

    /// The full, human-readable report — the text the user copies out of Settings when they
    /// decide to hand a crash over. Already redacted: it is built from stored fields, and
    /// every stored string went through ``LogRedaction`` at construction.
    public var reportText: String {
        var lines: [String] = ["[\(Self.stampFormatter.string(from: occurredAt))] \(headline)"]
        appendIfPresent("build", appBuildVersion, to: &lines)
        appendIfPresent("arch", platformArchitecture, to: &lines)
        if let exceptionType { lines.append("  exceptionType: \(exceptionType)") }
        if let exceptionCode { lines.append("  exceptionCode: \(exceptionCode)") }
        if let signal { lines.append("  signal: \(signal)") }
        if !frames.isEmpty {
            lines.append("  stack:")
            lines.append(contentsOf: frames.map { "    \($0.line)" })
        }
        return lines.joined(separator: "\n")
    }

    private func appendIfPresent(_ label: String, _ value: String?, to lines: inout [String]) {
        guard let value, !value.isEmpty else { return }
        lines.append("  \(label): \(value)")
    }

    nonisolated(unsafe) private static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

/// LT-05 — turns a MetricKit `MXDiagnosticPayload` JSON document into ``CrashDiagnosticRecord``s.
///
/// The parser takes `Data`, not an `MXDiagnosticPayload`, on purpose. MetricKit is a system
/// framework whose payloads cannot be constructed in a test, and the app target is the only
/// place that should import it. Its documented JSON serialisation is a stable, inspectable
/// boundary: the system layer calls `jsonRepresentation()` and hands the bytes over, and this
/// parser — the part that decides what is kept and what is thrown away — is exercised against
/// fixtures with no MetricKit, no crash and no UI in sight.
public enum CrashDiagnosticPayloadParser {
    /// Frames past this depth are dropped. The interesting part of a crash stack is its top;
    /// the tail is runtime and dispatch plumbing, and an unbounded stack would let one
    /// pathological payload dominate the retention budget.
    public static let maxFrames = 40

    public static func records(fromPayloadJSON data: Data, receivedAt: Date) -> [CrashDiagnosticRecord] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        let fallbackDate = timestamp(root["timeStampEnd"]) ?? receivedAt
        let rootVersion = string(root["appVersion"])
        let crashes = diagnostics(root["crashDiagnostics"]).map {
            record(kind: .crash, diagnostic: $0, fallbackDate: fallbackDate, rootVersion: rootVersion)
        }
        let hangs = diagnostics(root["hangDiagnostics"]).map {
            record(kind: .hang, diagnostic: $0, fallbackDate: fallbackDate, rootVersion: rootVersion)
        }
        return crashes + hangs
    }

    private static func diagnostics(_ value: Any?) -> [[String: Any]] {
        (value as? [[String: Any]]) ?? []
    }

    private static func record(
        kind: CrashDiagnosticKind,
        diagnostic: [String: Any],
        fallbackDate: Date,
        rootVersion: String?
    ) -> CrashDiagnosticRecord {
        let meta = (diagnostic["diagnosticMetaData"] as? [String: Any]) ?? [:]
        // MetricKit has spelled the two version fields differently across releases (and puts
        // `appVersion` at payload level in some), so both spellings are accepted rather than
        // letting a rename quietly produce version-less reports.
        return CrashDiagnosticRecord(
            kind: kind,
            occurredAt: fallbackDate,
            appVersion: string(meta["appVersion"]) ?? string(meta["applicationVersion"]) ?? rootVersion,
            appBuildVersion: string(meta["appBuildVersion"]) ?? string(meta["applicationBuildVersion"]),
            osVersion: string(meta["osVersion"]),
            platformArchitecture: string(meta["platformArchitecture"]),
            signal: int(meta["signal"]),
            exceptionType: int(meta["exceptionType"]),
            exceptionCode: int(meta["exceptionCode"]),
            terminationReason: string(meta["terminationReason"]),
            hangDurationSeconds: seconds(meta["hangDuration"]),
            frames: frames(in: diagnostic["callStackTree"])
        )
    }

    /// The attributed thread's stack, flattened depth-first.
    ///
    /// MetricKit nests frames through `subFrames` and marks the thread that faulted with
    /// `threadAttributed`. When nothing is marked — hangs frequently are not — the first
    /// stack is used, which is the one MetricKit puts first for exactly that reason.
    private static func frames(in callStackTree: Any?) -> [CrashDiagnosticFrame] {
        guard let tree = callStackTree as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]],
              let stack = stacks.first(where: { $0["threadAttributed"] as? Bool == true }) ?? stacks.first
        else { return [] }

        var out: [CrashDiagnosticFrame] = []
        appendFrames(stack["callStackRootFrames"] as? [[String: Any]] ?? [], to: &out)
        return out
    }

    private static func appendFrames(_ raw: [[String: Any]], to out: inout [CrashDiagnosticFrame]) {
        for frame in raw {
            guard out.count < maxFrames else { return }
            out.append(
                CrashDiagnosticFrame(
                    binaryName: string(frame["binaryName"]) ?? "?",
                    binaryUUID: string(frame["binaryUUID"]),
                    offset: int(frame["offsetIntoBinaryTextSegment"]) ?? 0
                )
            )
            appendFrames(frame["subFrames"] as? [[String: Any]] ?? [], to: &out)
        }
    }

    // MARK: - Lenient scalar reads
    //
    // MetricKit's JSON is not a contract we control, and the same field has been observed
    // both as a number and as a string across OS releases. Reading leniently keeps one
    // changed representation from silently emptying a whole report.

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func seconds(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        // `"2500 ms"` — MetricKit's measurement fields serialise with their unit attached.
        guard let text = value as? String else { return nil }
        let scanner = Scanner(string: text)
        guard let magnitude = scanner.scanDouble() else { return nil }
        let unit = text.dropFirst(scanner.currentIndex.utf16Offset(in: text))
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return unit == "ms" ? magnitude / 1000 : magnitude
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return payloadStampFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// MetricKit stamps payloads `2026-07-22 09:41:03`, without a zone marker.
    private static let payloadStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
