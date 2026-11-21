import SwiftUI
import MacUpdaterCore

/// When the Updates list may be touched, and when starting a batch is allowed.
///
/// The rule used to live in three places — the button's `.disabled`, the ⌘⏎ menu action and
/// nowhere at all for the rows — and the three had already drifted apart. A quiet refresh
/// (`ScanStore.isRefreshing`) closes all of them at once: the list on screen is the one the
/// scan is replacing, so a selection made against it is a selection made against last time's
/// answer, and a batch started from it installs whatever the scan settles on instead.
enum ScanSelectionGate {
    /// Whether the rows, their checkboxes and "Zaznacz wszystko" accept input right now.
    static func allowsSelection(isRefreshing: Bool) -> Bool {
        !isRefreshing
    }

    /// Whether anything on the Updates screen below its header accepts input right now — rows,
    /// banner actions, the plan preview, the stale-cask card and the manual installs. A running
    /// update owns the whole screen until it lands; only its own overlay stays live.
    static func allowsScreenInteraction(isUpdating: Bool) -> Bool {
        !isUpdating
    }

    /// Whether the list-wide "Zaznacz wszystko" accepts input. It sits in the list header,
    /// outside the regions the other two gates disable, so it must ask both.
    static func allowsListSelection(isRefreshing: Bool, isUpdating: Bool) -> Bool {
        allowsSelection(isRefreshing: isRefreshing) && allowsScreenInteraction(isUpdating: isUpdating)
    }

    /// Whether an in-place scan is running over rows, so the list header says why they cannot
    /// be selected (`ListHeaderGroupingSlot`). Nothing covers the rows; an empty state has none
    /// to stand down, so it gets no note.
    static func coversList(isRefreshing: Bool, showsRows: Bool) -> Bool {
        isRefreshing && showsRows
    }

    /// Whether a batch update may be started right now — by the button or by ⌘⏎.
    static func allowsUpdateRun(isRefreshing: Bool, isUpdating: Bool, hasTargets: Bool) -> Bool {
        !isRefreshing && !isUpdating && hasTargets
    }
}

/// What a running scan says about itself: how far it has got, and which command it is on.
///
/// A phase the scan has not reported yet is `nil` rather than zero — between the refresh flag
/// going up and the first phase landing, and after a finished run leaves `.finished` standing,
/// a bar drawn from `ScanProgress.fractionCompleted` would claim a position the scan has not
/// taken.
struct ScanBusyPresentation: Equatable {
    /// How far the scan has got, 0…1. `nil` while it has not named a phase.
    let fraction: Double?
    /// The command the current phase runs, e.g. `brew outdated`. `nil` for the same reason.
    let phaseLabel: String?

    init(progress: ScanProgress?) {
        guard case .running(let phase) = progress else {
            fraction = nil
            phaseLabel = nil
            return
        }
        fraction = phase.fractionCompleted
        phaseLabel = phase.commandLabel
    }

    /// What VoiceOver reads for the phase strip: the phase, or just that something is running.
    var accessibilityValue: String {
        phaseLabel ?? tr("Trwa skanowanie")
    }
}

/// The first scan, drawn full-screen while there is no result to keep on screen.
///
/// A scan over a result used to draw this scene too, over the list; scaling it down for that
/// overlay is what once made the two look like different screens, so the scene has no size
/// knob and owns its padding. UXP-13 took the overlay away — the band and the list header
/// report a scan in place — so this is the scan's only full scene. Its caption names the step
/// the scan is on, from the same `ScanPhaseCopy` as the band's headline.
struct ScanProgressScene: View {
    let progress: ScanProgress?
    var catalogRefreshing: Bool = false

    private var presentation: ScanBusyPresentation { ScanBusyPresentation(progress: progress) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // M2(c) — this screen used to animate five invented command bars on a timer,
            // regardless of what the scan was doing or how long it would take. The scan is
            // strictly sequential, so the bar reports the phase it is genuinely in.
            ProgressView(value: presentation.fraction ?? 0)
                .progressViewStyle(.linear)
                .tint(Color.wegaHoney)
                // A linear ProgressView reports a nonzero intrinsic width, which — with no
                // upper bound — propagates up and pushes the detail column wide enough to
                // shove the sidebar off-screen. Pin it elastic (0…∞) so it fills, not forces.
                .frame(minWidth: 0, maxWidth: .infinity)
                // The command behind the phase is for the curious; VoiceOver still hears it
                // through `ScanBusyPresentation.phaseLabel`.
                .help(presentation.phaseLabel ?? "")
            SniffingScene(
                caption: ScanPhaseCopy.caption(progress: progress, catalogRefreshing: catalogRefreshing),
                thoughts: Self.scanThoughts
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
        }
        // The scene fills the detail column and demands no minimum of its own, so the sidebar
        // keeps the exact width (and inset) it has when idle.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }

    /// What Wega thinks about while a scan runs. Shared, so the scan says the same things
    /// whichever screen it is drawn on.
    static let scanThoughts: [String] = [
        tr("Czy ten cask jest świeży?"),
        tr("Coś tu pachnie aktualizacją"),
        tr("Porównuję wersje…"),
        tr("Sprawdzam, czy aplikacje same się aktualizują…"),
        tr("Hau, ta wersja pachnie świeżo!"),
        tr("Łapię trop wersji"),
        "0x4A 0x65 0x6C 0x6C 0x79",
        tr("Mhm… nowa wersja?"),
        tr("Zaglądam do środka aplikacji…"),
        tr("Ten cask wymaga odświeżenia")
    ]
}
