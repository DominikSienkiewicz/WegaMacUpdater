import SwiftUI
import MacUpdaterCore

/// A running update, drawn over everything on the Updates screen it could be raced by.
///
/// While a batch installs, the rows, their checkboxes, the banner actions, the stale-cask card
/// and the manual "install" buttons used to stay live. Each of them either changes a selection
/// the run has already committed to, or starts a second package-manager operation that
/// `UpgradeMutex` would refuse with a danger banner mid-run. The screen now belongs to the run
/// until it lands: the content below is disabled, a veil of the window's own background
/// (`scrimOpacity`) stands it down, and a note says why. A material blurred the rows into an
/// empty column, so the veil keeps them readable instead.
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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// How much of the window's background lies over the screen: enough to read as stood down,
    /// little enough that every row stays legible. It was the scan's veil; UXP-13 removed the
    /// scan's overlay, so the run owns it now. Computed, because a generic type cannot store it.
    static var scrimOpacity: Double { 0.5 }

    /// UXP-22 — the veil drawn for the current Reduce Transparency setting. With the setting on
    /// there is no veil at all: an opaque one would hide the rows the run is installing, so the
    /// rows stay as they are and only the disabled screen says they are locked.
    static func scrim(reduceTransparency: Bool) -> Double {
        reduceTransparency ? 0 : scrimOpacity
    }

    var body: some View {
        VStack(spacing: 12) {
            note
                .padding(24)
            Spacer(minLength: 0)
            if let logLines {
                BrewLogPanel(lines: logLines, onClose: onHideLog)
                    .padding(.horizontal, WegaLayout.listGutter)
            }
            runBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A veil of no opacity takes no clicks; the shape keeps the run's layer taking the ones it took.
        .background(Color(nsColor: .windowBackgroundColor).opacity(Self.scrim(reduceTransparency: reduceTransparency)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Trwa aktualizacja"))
    }

    /// Why the list is locked. Under Reduce Transparency it sits on a solid surface instead of glass.
    @ViewBuilder
    private var note: some View {
        let text = Text(UpdateRunCopy.note(isStopping: isStopping))
            .font(.wega(.subheadline))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        if reduceTransparency {
            text.background(Color.wegaRecessedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            text.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
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
        isStopping
            ? tr("Kończę rozpoczęte instalacje, nowych nie zaczynam")
            : tr("Zatrzymaj po rozpoczętych instalacjach")
    }

    static func note(isStopping: Bool) -> String {
        isStopping
            ? tr("Przerywam po bieżącym pakiecie — kolejne nie wystartują.")
            : tr("Do końca aktualizacji lista jest zablokowana. Możesz ją przerwać — bieżący pakiet dokończę, kolejnych nie zacznę.")
    }
}
