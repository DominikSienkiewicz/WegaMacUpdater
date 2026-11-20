import SwiftUI
import MacUpdaterCore

/// A running update, drawn over everything on the Updates screen it could be raced by.
///
/// While a batch installs, the rows, their checkboxes, the banner actions, the stale-cask card
/// and the manual "install" buttons used to stay live. Each of them either changes a selection
/// the run has already committed to, or starts a second package-manager operation that
/// `UpgradeMutex` would refuse with a danger banner mid-run. The screen now belongs to the run
/// until it lands: the content below is disabled, the veil a scan in place uses
/// (`ScanBusyOverlay.scrimOpacity`) stands it down, and a note says why. A material blurred the
/// rows into an empty column, so the veil keeps them readable instead.
///
/// UX-20 — the run itself takes a bar at the bottom of the list (the shared
/// `wegaBottomBar()` chrome) instead of a card in the middle of the screen: progress, the log
/// and the one action that still makes sense, stopping. It stays inside this overlay, the one
/// live layer above the disabled screen, so the stop button is never greyed out with what it
/// covers.
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
        VStack(spacing: 12) {
            Text(UpdateRunCopy.note(isStopping: isStopping))
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(24)
            Spacer(minLength: 0)
            if let logLines {
                BrewLogPanel(lines: logLines, onClose: onHideLog)
                    .padding(.horizontal, WegaLayout.listGutter)
            }
            runBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(ScanBusyOverlay.scrimOpacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Trwa aktualizacja"))
    }

    /// The bar at the bottom of the list, carrying the run.
    private var runBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Aktualizuję wybrane pakiety"))
                    .font(.wega(.callout, weight: .semibold))
                progress()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if logLines == nil {
                Button(tr("Pokaż log"), action: onShowLog)
                    .buttonStyle(.glass)
            }
            Button(UpdateRunCopy.stopLabel(isStopping: isStopping), role: .cancel, action: onCancel)
                .buttonStyle(.glass)
                .disabled(isStopping)
                .help(tr("Zatrzymam po bieżącym pakiecie — trwającej instalacji nie przerywam w połowie."))
        }
        .wegaBottomBar()
    }
}

/// UX-20 — what the run says about stopping, before and after the stop is requested.
enum UpdateRunCopy {
    static func stopLabel(isStopping: Bool) -> String {
        isStopping ? tr("Przerywam…") : tr("Zatrzymaj po bieżącym")
    }

    static func note(isStopping: Bool) -> String {
        isStopping
            ? tr("Przerywam po bieżącym pakiecie — kolejne nie wystartują.")
            : tr("Do końca aktualizacji lista jest zablokowana. Możesz ją przerwać — bieżący pakiet dokończę, kolejnych nie zacznę.")
    }
}
