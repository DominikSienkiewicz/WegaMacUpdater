import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("BugReportEnvironment")
struct BugReportEnvironmentTests {

    static func snapshot(lastScanAt: Date? = Date(timeIntervalSince1970: 1_769_990_000),
                         complete: Bool = true) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            runtime: .init(
                generatedAt: Date(timeIntervalSince1970: 1_770_000_000),
                appVersion: "1.4.2", appBuild: "812",
                bundleIdentifier: "pl.wega.MacUpdater",
                osVersion: "Version 26.1 (Build 26A1)",
                architecture: "arm64", processorCount: 12
            ),
            managers: [
                .init(name: "Homebrew", version: "4.3.0", detected: true),
                .init(name: "mas-cli", version: nil, detected: false),
                .init(name: "npm", version: nil, detected: true),
            ],
            helper: .init(status: "enabled", expectedVersion: "3",
                          reportedVersion: "3", teamIDConfigured: true),
            schedule: .init(interval: "daily", lastCheck: nil, nextCheck: nil,
                            lastCheckFailed: false, launchAtLogin: true,
                            backgroundUpdatesEnabled: false),
            scan: .init(lastScanAt: lastScanAt, complete: complete, sourceResults: []),
            system: .init(freeDiskBytes: nil, signatures: [],
                          appManagementPermission: "granted"),
            artifacts: .init(history: [], logFiles: [], logWriteFailureCount: 0)
        )
    }

    private func byLabel(_ snapshot: DiagnosticsSnapshot) -> [String: String] {
        Dictionary(uniqueKeysWithValues:
            BugReportEnvironment.fields(from: snapshot).map { ($0.label, $0.value) })
    }

    @Test func reportsTheFactsAMaintainerAlwaysAsksFor() {
        let fields = byLabel(Self.snapshot())
        #expect(fields["Wega"] == "1.4.2 (812)")
        #expect(fields["macOS"] == "Version 26.1 (Build 26A1) (arm64)")
        #expect(fields["Homebrew"] == "4.3.0")
        #expect(fields["mas-cli"] == "not detected")
        #expect(fields["npm"] == "detected, version unknown")
        #expect(fields["Privileged helper"] == "enabled")
    }

    @Test func labelsAreStableAndOrdered() {
        let labels = BugReportEnvironment.fields(from: Self.snapshot()).map(\.label)
        #expect(labels.first == "Wega")
        #expect(labels.contains("Last scan"))
    }

    @Test func aScanThatNeverRanSaysSoRatherThanBeingOmitted() {
        #expect(byLabel(Self.snapshot(lastScanAt: nil, complete: false))["Last scan"] == "never")
    }

    @Test func anIncompleteScanIsMarkedAsSuch() throws {
        let value = try #require(byLabel(Self.snapshot(complete: false))["Last scan"])
        #expect(value.hasSuffix("(incomplete)"))
    }
}
