import SwiftUI
import MacUpdaterCore

/// A running update, drawn over everything on the Updates screen it could be raced by.
///
/// While a batch installs, the rows, their checkboxes, the banner actions, the stale-cask card
/// and the manual "install" buttons used to stay live. Each of them either changes a selection
/// the run has already committed to, or starts a second package-manager operation that
/// `UpgradeMutex` would refuse with a danger banner mid-run. The screen now belongs to the run
/// until it lands: the content below is disabled and this overlay says what is happening and
/// offers the one action that still makes sense — stopping.
///
/// Stopping keeps REL-12's contract: the package being installed finishes, and nothing queued
/// after it starts. The button says so rather than promising an instant stop.
///
/// The progress row is passed in rather than built here, so the store's value is what the
/// Updates screen renders — the overlay owns layout, not state.
struct UpdateRunOverlay<Progress: View>: View {
    /// Whether a stop has already been requested; the button then reports it instead.
    let isStopping: Bool
    /// The live package-manager log, or `nil` while the user has it collapsed.
    let logLines: [String]?
    let onCancel: () -> Void
    let onShowLog: () -> Void
    let onHideLog: () -> Void
    @ViewBuilder let progress: () -> Progress

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Aktualizuję wybrane pakiety"))
                .font(.wega(.title3, weight: .semibold))
            progress()
            Text(isStopping
                 ? tr("Przerywam po bieżącym pakiecie — kolejne nie wystartują.")
                 : tr("Do końca aktualizacji lista jest zablokowana. Możesz ją przerwać — bieżący pakiet dokończę, kolejnych nie zacznę."))
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(isStopping ? tr("Przerywam…") : tr("Anuluj"), role: .cancel, action: onCancel)
                    .disabled(isStopping)
                    .help(tr("Zatrzymam po bieżącym pakiecie — trwającej instalacji nie przerywam w połowie."))
                Spacer()
                if logLines == nil {
                    Button(tr("Pokaż log"), action: onShowLog)
                        .buttonStyle(.link)
                }
            }
            if let logLines {
                BrewLogPanel(lines: logLines, onClose: onHideLog)
            }
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: WegaLayout.cardRadius))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Trwa aktualizacja"))
    }
}
