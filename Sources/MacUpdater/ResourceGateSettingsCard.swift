import MacUpdaterCore
import SwiftUI

/// User-tunable thresholds for the hard preflight shared by foreground and background updates.
struct ResourceGateSettingsCard: View {
    @AppStorage(DownloadGate.Configuration.largeDownloadThresholdMBKey)
    private var largeDownloadThresholdMB = DownloadGate.Configuration.defaultLargeDownloadThresholdMB
    @AppStorage(DownloadGate.Configuration.lowBatteryThresholdPercentKey)
    private var lowBatteryThresholdPercent = DownloadGate.Configuration.defaultLowBatteryThresholdPercent
    @AppStorage(DownloadGate.Configuration.unpackedSizeMultiplierKey)
    private var unpackedSizeMultiplier = DownloadGate.Configuration.defaultUnpackedSizeMultiplier
    @AppStorage(DownloadGate.Configuration.safetyMarginGBKey)
    private var safetyMarginGB = DownloadGate.Configuration.defaultSafetyMarginGB

    var body: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "externaldrive.badge.checkmark", title: tr("Bramka zasobów"),
                               titleTinted: true)

                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Wega sprawdza miejsce, łącze, baterię i temperaturę przed snapshotem i pobraniem."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    gateStepper(tr("Duże pobranie"), value: "\(largeDownloadThresholdMB) MB") {
                        Stepper("", value: $largeDownloadThresholdMB, in: 50...5_000, step: 50).labelsHidden()
                    }
                    gateStepper(tr("Niska bateria"), value: "\(lowBatteryThresholdPercent)%") {
                        Stepper("", value: $lowBatteryThresholdPercent, in: 5...100, step: 5).labelsHidden()
                    }
                    gateStepper(tr("Mnożnik rozpakowania"), value: unpackedSizeMultiplier.formatted(.number.precision(.fractionLength(1)))) {
                        Stepper("", value: $unpackedSizeMultiplier, in: 0.5...5, step: 0.5).labelsHidden()
                    }
                    gateStepper(tr("Margines dysku"), value: "\(safetyMarginGB) GB") {
                        Stepper("", value: $safetyMarginGB, in: 0...20).labelsHidden()
                    }
                }
                .padding(14)
            }
        }
    }

    private func gateStepper<Control: View>(
        _ title: String,
        value: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            control()
        }
    }
}
