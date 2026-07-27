import Foundation
import Testing
@testable import MacUpdaterCore

/// LT-05 — local crash reporting through MetricKit.
///
/// The July 22 crash was diagnosed from a system report the user produced and handed over by
/// hand. MetricKit removes the *finding* of that report from the job — and nothing else: the
/// reports are stored on the user's Mac and go nowhere until they choose to copy them out.
///
/// The suite drives the whole decision path — parse, redact, retain, deduplicate, gate on
/// consent — through the pure Core types and a stand-in diagnostic source. MetricKit itself
/// is unreachable from a unit test (its payloads cannot be constructed and its delivery
/// cannot be provoked), which is exactly why the app target's role is reduced to
/// `MetricKitCrashDiagnosticSource`: subscribe, serialise the payload, hand over the bytes.
@Suite("LT-05 — crash reporting (MetricKit)")
@MainActor
struct LT05CrashReportingTests {

    // MARK: - Fixtures

    /// Shaped like a real `MXDiagnosticPayload.jsonRepresentation()`: metadata that identifies
    /// the *machine* (`regionFormat`, `deviceType`), a memory dump (`virtualMemoryRegionInfo`)
    /// and a nested, thread-attributed call stack.
    private func crashPayload(
        terminationReason: String = "Namespace SIGNAL, Code 0xb",
        timeStampEnd: String = "2026-07-22 09:41:03"
    ) -> Data {
        Data("""
        {
          "timeStampBegin": "2026-07-22 00:00:00",
          "timeStampEnd": "\(timeStampEnd)",
          "crashDiagnostics": [
            {
              "version": "1.0.0",
              "diagnosticMetaData": {
                "appVersion": "1.4.0",
                "appBuildVersion": "231",
                "osVersion": "macOS 26.0 (26A123)",
                "platformArchitecture": "arm64e",
                "regionFormat": "PL",
                "deviceType": "Mac15,3",
                "signal": 11,
                "exceptionType": 1,
                "exceptionCode": 0,
                "terminationReason": "\(terminationReason)",
                "virtualMemoryRegionInfo": "0x0 is not in any region. Bytes before: 4310253568"
              },
              "callStackTree": {
                "callStackPerThread": true,
                "callStacks": [
                  {
                    "threadAttributed": false,
                    "callStackRootFrames": [
                      { "binaryName": "libsystem_kernel.dylib", "offsetIntoBinaryTextSegment": 11 }
                    ]
                  },
                  {
                    "threadAttributed": true,
                    "callStackRootFrames": [
                      {
                        "binaryName": "WegaMacUpdater",
                        "binaryUUID": "1B0C51D4-0000-3B4C-9C7A-000000000001",
                        "offsetIntoBinaryTextSegment": 421344,
                        "address": 4386531756,
                        "sampleCount": 1,
                        "subFrames": [
                          { "binaryName": "SwiftUI", "offsetIntoBinaryTextSegment": 9912 }
                        ]
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
        """.utf8)
    }

    private func hangPayload(duration: String) -> Data {
        Data("""
        {
          "timeStampEnd": "2026-07-22 10:00:00",
          "hangDiagnostics": [
            {
              "diagnosticMetaData": { "appVersion": "1.4.0", "hangDuration": \(duration) },
              "callStackTree": { "callStacks": [] }
            }
          ]
        }
        """.utf8)
    }

    private func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LT05CrashReporting/\(UUID().uuidString)", isDirectory: true)
        return url
    }

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "wega.tests.lt05.\(UUID().uuidString)")!
    }

    private func store(
        directory: URL? = nil,
        maxRecords: Int = CrashDiagnosticStore.defaultMaxRecords,
        maxAge: TimeInterval = CrashDiagnosticStore.defaultMaxAge,
        now: @escaping () -> Date = Date.init
    ) -> CrashDiagnosticStore {
        CrashDiagnosticStore(
            directory: directory ?? scratchDirectory(),
            maxRecords: maxRecords,
            maxAge: maxAge,
            now: now
        )
    }

    // MARK: - Parsing

    @Test("A crash payload becomes a record carrying what diagnoses the crash")
    func parsesCrashDiagnostic() throws {
        let records = CrashDiagnosticPayloadParser.records(
            fromPayloadJSON: crashPayload(), receivedAt: Date()
        )

        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.kind == .crash)
        #expect(record.appVersion == "1.4.0")
        #expect(record.appBuildVersion == "231")
        #expect(record.osVersion == "macOS 26.0 (26A123)")
        #expect(record.platformArchitecture == "arm64e")
        #expect(record.signal == 11)
        #expect(record.exceptionType == 1)
        #expect(record.exceptionCode == 0)
        #expect(record.terminationReason == "Namespace SIGNAL, Code 0xb")

        // The crash time comes from the payload, not from the moment of delivery, so the same
        // crash redelivered later is still recognised as the same crash.
        let expected = Date(timeIntervalSince1970: 1_784_713_263)  // 2026-07-22T09:41:03Z
        #expect(abs(record.occurredAt.timeIntervalSince(expected)) < 1)
    }

    @Test("The attributed thread's stack is flattened depth-first, addresses dropped")
    func parsesAttributedCallStack() throws {
        let records = CrashDiagnosticPayloadParser.records(
            fromPayloadJSON: crashPayload(), receivedAt: Date()
        )
        let record = try #require(records.first)

        // The non-attributed thread is skipped; the attributed one keeps parent then child.
        #expect(record.frames.map(\.binaryName) == ["WegaMacUpdater", "SwiftUI"])
        #expect(record.frames.first?.offset == 421_344)
        #expect(record.frames.first?.binaryUUID == "1B0C51D4-0000-3B4C-9C7A-000000000001")

        // The slid runtime address is useless off-device and is not carried.
        #expect(!record.reportText.contains("4386531756"))
    }

    @Test("Fields that describe the machine or its memory never reach a record")
    func dropsMachineIdentifyingMetadata() throws {
        let records = CrashDiagnosticPayloadParser.records(
            fromPayloadJSON: crashPayload(), receivedAt: Date()
        )
        let text = try #require(records.first).reportText

        #expect(!text.contains("Mac15,3"), "the Mac model is not needed to fix a crash: \(text)")
        #expect(!text.contains("PL"), "the user's locale is not diagnostic data: \(text)")
        #expect(!text.contains("Bytes before"), "no memory-region dump: \(text)")
    }

    @Test("Anything MetricKit puts in a string is redacted like a log line")
    func redactsPathsInsideDiagnosticText() throws {
        let payload = crashPayload(
            terminationReason: "Namespace SIGNAL, dyld: /Users/alice/Library/Wega/plugin.dylib"
        )

        let record = try #require(
            CrashDiagnosticPayloadParser.records(fromPayloadJSON: payload, receivedAt: Date()).first
        )

        #expect(!record.reportText.contains("alice"), "\(record.reportText)")
        #expect(!record.reportText.contains("/Users/"), "\(record.reportText)")
        #expect(record.reportText.contains("[path]"), "\(record.reportText)")
        #expect(record.reportText.contains("Namespace SIGNAL"), "diagnostic text survives")
    }

    @Test("An unbounded stack cannot swallow the retention budget")
    func capsFrameCount() throws {
        let deep = (0..<200).map {
            #"{ "binaryName": "F\#($0)", "offsetIntoBinaryTextSegment": \#($0) }"#
        }.joined(separator: ",")
        let payload = Data("""
        {
          "crashDiagnostics": [
            { "diagnosticMetaData": {}, "callStackTree": { "callStacks": [
              { "threadAttributed": true, "callStackRootFrames": [\(deep)] }
            ] } }
          ]
        }
        """.utf8)

        let record = try #require(
            CrashDiagnosticPayloadParser.records(fromPayloadJSON: payload, receivedAt: Date()).first
        )
        #expect(record.frames.count == CrashDiagnosticPayloadParser.maxFrames)
    }

    @Test("Hang duration is read whether MetricKit serialises it as a number or a measurement")
    func parsesHangDuration() {
        let asNumber = CrashDiagnosticPayloadParser.records(
            fromPayloadJSON: hangPayload(duration: "2.5"), receivedAt: Date()
        ).first
        let asMeasurement = CrashDiagnosticPayloadParser.records(
            fromPayloadJSON: hangPayload(duration: "\"2500 ms\""), receivedAt: Date()
        ).first

        #expect(asNumber?.kind == .hang)
        #expect(asNumber?.hangDurationSeconds == 2.5)
        #expect(asMeasurement?.hangDurationSeconds == 2.5)
    }

    @Test("Garbage in is nothing out, not a crash inside the crash reporter")
    func survivesUnparseablePayload() {
        #expect(CrashDiagnosticPayloadParser.records(fromPayloadJSON: Data("not json".utf8), receivedAt: Date()).isEmpty)
        #expect(CrashDiagnosticPayloadParser.records(fromPayloadJSON: Data("{}".utf8), receivedAt: Date()).isEmpty)
    }

    // MARK: - Store: retention, deduplication, permissions

    @Test("The same diagnostic delivered twice is stored once")
    func deduplicatesRedeliveredDiagnostics() {
        let subject = store()
        let parsed = CrashDiagnosticPayloadParser.records(fromPayloadJSON: crashPayload(), receivedAt: Date())

        #expect(subject.ingest(parsed).count == 1)
        #expect(subject.ingest(parsed).isEmpty, "MetricKit may hand the same crash over again")
        #expect(subject.records().count == 1)
    }

    /// The record id is derived from the crash, not from a per-process hash — otherwise a
    /// report read back after a relaunch would look new and the store would grow forever.
    @Test("Deduplication survives a relaunch")
    func recordIdentityIsStableAcrossStoreInstances() {
        let directory = scratchDirectory()
        let parsed = CrashDiagnosticPayloadParser.records(fromPayloadJSON: crashPayload(), receivedAt: Date())

        #expect(store(directory: directory).ingest(parsed).count == 1)
        #expect(store(directory: directory).ingest(parsed).isEmpty)
        #expect(store(directory: directory).records().count == 1)
    }

    @Test("Retention keeps the newest reports and drops the rest")
    func retainsNewestRecordsUpToTheCap() {
        // Recent enough that the age limit is not what is being measured here.
        let base = Date().addingTimeInterval(-3600)
        let subject = store(maxRecords: 3, now: { base.addingTimeInterval(3600) })
        let records = (0..<6).map {
            CrashDiagnosticRecord(kind: .crash, occurredAt: base.addingTimeInterval(Double($0) * 60),
                                  terminationReason: "reason-\($0)")
        }

        subject.ingest(records)
        let kept = subject.records()

        #expect(kept.count == 3)
        #expect(kept.map(\.terminationReason) == ["reason-5", "reason-4", "reason-3"])
    }

    @Test("Reports older than the retention window are forgotten")
    func dropsRecordsPastTheAgeLimit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let subject = store(maxAge: 60, now: { now })

        subject.ingest([
            CrashDiagnosticRecord(kind: .crash, occurredAt: now.addingTimeInterval(-10), terminationReason: "fresh"),
            CrashDiagnosticRecord(kind: .crash, occurredAt: now.addingTimeInterval(-600), terminationReason: "stale"),
        ])

        #expect(subject.records().map(\.terminationReason) == ["fresh"])
    }

    @Test("The report file is owner-only, like the log it sits next to")
    func writesOwnerOnlyFileAndDirectory() throws {
        let directory = scratchDirectory()
        let subject = store(directory: directory)
        subject.ingest([CrashDiagnosticRecord(kind: .crash, occurredAt: Date())])

        let filePermissions = try FileManager.default
            .attributesOfItem(atPath: subject.fileURL.path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default
            .attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber

        #expect(filePermissions?.int16Value == 0o600)
        #expect(directoryPermissions?.int16Value == 0o700)
    }

    @Test("Deleting the reports leaves nothing on disk")
    func clearRemovesEverything() {
        let subject = store()
        subject.ingest([CrashDiagnosticRecord(kind: .crash, occurredAt: Date())])

        subject.clear()

        #expect(subject.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: subject.fileURL.path))
        #expect(subject.reportText().isEmpty)
    }

    // MARK: - Consent gate

    @Test("Nothing is collected until the user opts in")
    func collectsNothingWhileOptedOut() {
        let source = FakeCrashDiagnosticSource()
        let subject = CrashReportingController(
            source: source, store: store(), defaults: scratchDefaults()
        )

        #expect(!subject.isEnabled, "crash reporting is off on a fresh install")
        #expect(source.startCount == 0, "the system source is never subscribed to while opted out")

        // Even a source that ignores the contract and keeps talking cannot write anything.
        subject.receive(payloadJSON: crashPayload())
        #expect(subject.records.isEmpty)
    }

    @Test("Opting in subscribes, opting out unsubscribes, and the choice is remembered")
    func optInDrivesTheSystemSubscription() {
        let defaults = scratchDefaults()
        let source = FakeCrashDiagnosticSource()
        let subject = CrashReportingController(source: source, store: store(), defaults: defaults)

        subject.setEnabled(true)
        #expect(source.startCount == 1)
        #expect(defaults.bool(forKey: CrashReportingController.defaultsKey))

        subject.setEnabled(false)
        #expect(source.stopCount == 1)
        #expect(!defaults.bool(forKey: CrashReportingController.defaultsKey))

        // A relaunch with the choice still on resubscribes by itself.
        subject.setEnabled(true)
        let relaunched = CrashReportingController(
            source: FakeCrashDiagnosticSource(), store: store(), defaults: defaults
        )
        #expect(relaunched.isEnabled)
    }

    @Test("An opted-in delivery is parsed, stored and surfaced")
    func storesDeliveredDiagnosticWhenOptedIn() {
        let source = FakeCrashDiagnosticSource()
        let subject = CrashReportingController(source: source, store: store(), defaults: scratchDefaults())

        subject.setEnabled(true)
        source.deliver(crashPayload())

        #expect(subject.records.count == 1)
        #expect(subject.records.first?.appVersion == "1.4.0")
        #expect(subject.reportText.contains("Namespace SIGNAL"))
    }

    @Test("Deleting the reports is independent of the switch")
    func clearingRecordsKeepsCollectionRunning() {
        let source = FakeCrashDiagnosticSource()
        let subject = CrashReportingController(source: source, store: store(), defaults: scratchDefaults())
        subject.setEnabled(true)
        source.deliver(crashPayload())

        subject.clearRecords()

        #expect(subject.records.isEmpty)
        #expect(subject.isEnabled)
        #expect(source.stopCount == 0)
    }

    // MARK: - The privacy promise, pinned at source level

    /// The feature's whole premise is that a crash report is data from the user's machine and
    /// stays there. That is a claim about code that does *not* exist, so it is pinned by
    /// inspection: no HTTP client, no URL request, no upload path anywhere in crash reporting.
    @Test("Crash reporting contains no path off the Mac")
    func crashReportingNeverUploadsAnything() throws {
        let files = [
            "Sources/MacUpdaterCore/CrashDiagnostics.swift",
            "Sources/MacUpdaterCore/CrashDiagnosticStore.swift",
            "Sources/MacUpdaterCore/CrashReporting.swift",
            "Sources/MacUpdater/MetricKitCrashDiagnosticSource.swift",
            "Sources/MacUpdater/CrashReportingSettingsCard.swift",
        ]
        let forbidden = ["URLSession", "URLRequest", "HTTPClient", "https://", "http://", "dataTask", "upload"]

        for file in files {
            let text = try code(in: file)
            for needle in forbidden {
                #expect(!text.contains(needle), "\(file) must not reach the network (\(needle))")
            }
        }
    }

    /// MetricKit can also hand over diagnostics recorded *before* the user opted in. Consent
    /// given now is consent from now on, so those historical payloads are never requested.
    @Test("Historical MetricKit payloads are not swept up on opt-in")
    func neverDrainsPastDiagnosticPayloads() throws {
        #expect(!(try code(in: "Sources/MacUpdater/MetricKitCrashDiagnosticSource.swift"))
            .contains("pastDiagnosticPayloads"))
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// A source file with its comment lines removed — these assertions are about what the code
    /// does, and a doc comment that *describes* the absence of an upload must not read as one.
    private func code(in relativePath: String) throws -> String {
        let text = try String(
            contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8
        )
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

/// Stands in for MetricKit so the consent gate can be exercised without a real crash.
private final class FakeCrashDiagnosticSource: CrashDiagnosticSource {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@MainActor @Sendable (Data) -> Void)?

    func startDelivering(to handler: @escaping @MainActor @Sendable (Data) -> Void) {
        startCount += 1
        self.handler = handler
    }

    func stopDelivering() {
        stopCount += 1
        handler = nil
    }

    @MainActor
    func deliver(_ payloadJSON: Data) {
        handler?(payloadJSON)
    }
}
