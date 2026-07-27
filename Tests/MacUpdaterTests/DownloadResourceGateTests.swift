import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Download resource gate")
struct DownloadResourceGateTests {
    private let generousDisk: Int64 = 20 * 1_024 * 1_024 * 1_024

    private var configuration: DownloadGate.Configuration {
        DownloadGate.Configuration(
            largeDownloadThresholdBytes: 100,
            lowBatteryThreshold: 0.25,
            unpackedSizeMultiplier: 2,
            safetyMarginBytes: 50
        )
    }

    private func decision(
        network: NetworkCondition = .unrestricted,
        power: PowerCondition = .plugged,
        availableDiskBytes: Int64? = nil
    ) -> DownloadGate.Decision {
        DownloadGate.decide(
            resources: .init(downloadBytes: 100, snapshotBytes: 40),
            availableDiskBytes: availableDiskBytes ?? generousDisk,
            network: network,
            power: power,
            configuration: configuration
        )
    }

    @Test func requiredDiskIncludesDownloadUnpackingSnapshotAndSafetyMargin() {
        let resources = DownloadGate.Resources(downloadBytes: 100, snapshotBytes: 40)

        #expect(resources.requiredDiskBytes(configuration: configuration) == 390)
    }

    @Test func meteredNetworkVetoesTheDownload() {
        let result = decision(network: .init(isExpensive: true, isConstrained: false))

        guard case .postpone(let reason) = result else {
            Issue.record("expected metered-network veto")
            return
        }
        #expect(reason.contains("taryfowe"))
    }

    @Test func hardGateDoesNotBypassMeteredNetworkForSmallDownloads() {
        let result = DownloadGate.decide(
            resources: .init(downloadBytes: 1, snapshotBytes: 0),
            availableDiskBytes: generousDisk,
            network: .init(isExpensive: true, isConstrained: false),
            power: .plugged,
            configuration: configuration
        )

        if case .postpone = result { return }
        Issue.record("expected the hard gate to veto even a small unattended download")
    }

    @Test func lowBatteryVetoesTheDownloadAtConfiguredThreshold() {
        let result = decision(power: .init(onBattery: true, batteryFraction: 0.24, thermalSerious: false))

        guard case .postpone(let reason) = result else {
            Issue.record("expected low-battery veto")
            return
        }
        #expect(reason.contains("baterii"))
    }

    @Test func thermalThrottlingVetoesTheDownload() {
        let result = decision(power: .init(onBattery: false, batteryFraction: nil, thermalSerious: true))

        guard case .postpone(let reason) = result else {
            Issue.record("expected thermal veto")
            return
        }
        #expect(reason.contains("termiczny"))
    }

    @Test func insufficientDiskVetoesBeforeOtherConditions() {
        let result = decision(
            network: .init(isExpensive: true, isConstrained: false),
            availableDiskBytes: 389
        )

        guard case .postpone(let reason) = result else {
            Issue.record("expected disk veto")
            return
        }
        #expect(reason.contains("miejsce"))
    }

    @Test func preferencesLoadConfiguredThresholdsInsteadOfHardCodedValues() throws {
        let suite = "wega-download-gate-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(350, forKey: DownloadGate.Configuration.largeDownloadThresholdMBKey)
        defaults.set(35, forKey: DownloadGate.Configuration.lowBatteryThresholdPercentKey)
        defaults.set(3.5, forKey: DownloadGate.Configuration.unpackedSizeMultiplierKey)
        defaults.set(4, forKey: DownloadGate.Configuration.safetyMarginGBKey)

        let loaded = DownloadGate.Configuration.load(from: defaults)

        #expect(loaded.largeDownloadThresholdBytes == 350 * 1_024 * 1_024)
        #expect(loaded.lowBatteryThreshold == 0.35)
        #expect(loaded.unpackedSizeMultiplier == 3.5)
        #expect(loaded.safetyMarginBytes == 4 * 1_024 * 1_024 * 1_024)
    }
}

@Suite("Download resource gate wiring")
struct DownloadResourceGateWiringTests {
    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(path), encoding: .utf8)
    }

    @Test func backgroundHardGateRunsBeforeSnapshot() throws {
        let text = try source("Sources/MacUpdater/BackgroundUpdater.swift")
        let gate = try #require(text.range(of: "let resourceDecision = await backgroundResourceDecision("))
        let veto = try #require(text.range(of: "guard case .allow = resourceDecision else"))
        let snapshot = try #require(text.range(of: "CaskRollbackGuard.snapshot("))

        #expect(gate.lowerBound < veto.lowerBound)
        #expect(veto.lowerBound < snapshot.lowerBound)
        #expect(text.contains("Aktualizacja w tle odroczona —"))
    }

    @Test func foregroundHardGateRunsBeforeSnapshot() throws {
        let text = try source("Sources/MacUpdater/ScanStore+Rollback.swift")
        let gate = try #require(text.range(of: "let resourceDecision = await foregroundResourceDecision("))
        let veto = try #require(text.range(of: "guard case .allow = resourceDecision else"))
        let snapshot = try #require(text.range(of: "snapshotCasks(caskNames, appPaths: appPaths, operation: operation)"))

        #expect(gate.lowerBound < veto.lowerBound)
        #expect(veto.lowerBound < snapshot.lowerBound)
    }
}
