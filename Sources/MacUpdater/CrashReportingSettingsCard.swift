import AppKit
import MacUpdaterCore
import SwiftUI

/// LT-05 — the opt-in switch for MetricKit crash reporting, plus what it has collected.
///
/// The card is the whole user-facing surface of the feature, and it is deliberately blunt
/// about the deal: the switch is off until turned on, the reports never leave the Mac, and
/// both "copy" and "delete" are the user's calls. There is no send button because there is
/// nowhere to send to — Wega has no crash-reporting endpoint.
struct CrashReportingSettingsCard: View {
    @ObservedObject private var controller = CrashReportingController.shared
    @State private var confirmingClear = false

    var body: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "ladybug", title: tr("Raportowanie awarii")) {
                    if controller.isEnabled {
                        WegaBadge(label: tr("Aktywne"), variant: .success)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Gdy Wega się wysypie albo zawiesi, macOS (MetricKit) przekazuje jej własny raport przy następnym uruchomieniu. Raport zostaje na tym Macu — Wega nigdzie go nie wysyła. Zapisujemy wersję, system, architekturę, powód zakończenia i ślad stosu; ścieżki i adresy są usuwane."))
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: Binding(
                        get: { controller.isEnabled },
                        set: { controller.setEnabled($0) }
                    )) {
                        Text(tr("Zbieraj lokalnie raporty awarii Wegi")).font(.wega(.callout))
                    }
                    .toggleStyle(.switch)

                    storedReports
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private var storedReports: some View {
        if controller.records.isEmpty {
            Text(tr("Brak zapisanych raportów."))
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
        } else {
            Text(trf("Zapisane raporty: %d (do 20, przez 90 dni)", controller.records.count))
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)

            if let latest = controller.records.first {
                Text(latest.headline)
                    .font(.wega(.subheadline, monospaced: true))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button {
                    copyReports()
                } label: {
                    Label(tr("Kopiuj raporty"), systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    Label(tr("Usuń raporty"), systemImage: "trash")
                }
                .controlSize(.small)
                .confirmationDialog(
                    tr("Usunąć zapisane raporty awarii?"),
                    isPresented: $confirmingClear
                ) {
                    Button(tr("Usuń raporty"), role: .destructive) { controller.clearRecords() }
                    Button(tr("Anuluj"), role: .cancel) {}
                }
            }
        }
    }

    /// The pasteboard is the only way a report leaves the app, and it takes a conscious click.
    private func copyReports() {
        let text = controller.reportText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
