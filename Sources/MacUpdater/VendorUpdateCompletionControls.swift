import SwiftUI
import MacUpdaterCore

struct VendorUpdateCompletionControls: View {
    let item: ManualOutdatedApp
    @EnvironmentObject private var scan: ScanStore
    @ObservedObject private var upgrades = UpgradeCoordinator.shared

    private var pending: Bool { scan.vendorHandoffs.contains { $0.path == item.path } }
    private var checking: Bool { scan.vendorCheckPath == item.path.path }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if pending {
                Text(tr("Dokończ u producenta, potem sprawdź tę aplikację."))
                    .font(.wega(.footnote))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if checking {
                    ProgressView().controlSize(.small)
                    Text(tr("Sprawdzam tę instalację…")).font(.wega(.footnote))
                    Button(tr("Anuluj")) { scan.vendorCheckTask?.cancel() }
                } else {
                    Button { scan.startVendorCheck(item) } label: {
                        Label(tr("Sprawdź tę aplikację"), systemImage: "arrow.clockwise")
                    }
                    .disabled(!scan.allowsVendorCheck || upgrades.state != .idle)
                    .help(tr("Odczytaj wersję pod tą ścieżką i sprawdź źródło producenta, bez pełnego skanu."))
                    if pending {
                        Button(tr("Zakończ śledzenie")) { scan.dismissVendorHandoff(item) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(tr("Kończy oczekiwanie. Nie potwierdza aktualizacji ani nie usuwa aplikacji."))
                    }
                }
            }
            .controlSize(.small)
            if let message = scan.vendorMessages[item.path.path] {
                Text(tr(message))
                    .font(.wega(.footnote))
                    .foregroundStyle(Color.wegaDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
        }
    }
}
