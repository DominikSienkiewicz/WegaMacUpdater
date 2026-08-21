import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("WegaLog detail")
struct WegaLogDetailTests {

    @Test func detailIsStoredUnredactedInLogStore() async throws {
        // Arrange: construct a unique marker and an original path
        let marker = UUID().uuidString
        let originalPath = "/Users/ala/Desktop/a.app"
        let message = "brew update failed \(marker)"
        let detail = LogDetail(
            fields: [.init(key: "command", value: "cp \(originalPath) /Applications")],
            output: nil
        )

        // Act: call WegaLog with the detail
        WegaLog.error(.app, message, detail: detail)

        // Assert: poll the LogStore on the main actor until the entry appears
        let entry = try await findEntryWithMarker(marker, timeout: 2.0)

        // Verify the detail is present and un-redacted
        #expect(entry.detail != nil, "LogEntry should carry the detail")
        guard let storedDetail = entry.detail else { return }

        // The original path must be in the field value (un-redacted)
        let fieldValue = storedDetail.fields.first?.value ?? ""
        #expect(fieldValue.contains(originalPath), "Original path must be stored un-redacted in LogStore")

        // For contrast: when redacted, the path is gone
        let redactedValue = LogRedaction.redact(fieldValue)
        #expect(!redactedValue.contains(originalPath), "LogRedaction.redact must remove the original path")
    }

    // Helper: poll on the main actor for an entry matching the marker
    private func findEntryWithMarker(_ marker: String, timeout: Double) async throws -> LogEntry {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let entry = await MainActor.run {
                LogStore.shared.entries.first { $0.message.contains(marker) }
            }
            if let entry {
                return entry
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        throw TestError.entryNeverArrived(marker: marker)
    }

    enum TestError: Error {
        case entryNeverArrived(marker: String)

        var description: String {
            switch self {
            case .entryNeverArrived(let marker):
                return "LogStore entry with marker '\(marker)' never arrived within timeout"
            }
        }
    }
}
