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

    /// Whether the in-place scan's overlay covers the list. It stands rows down, so it covers
    /// rows only: over an empty state its material just veiled Wega and her tricks for the
    /// whole scan, with nothing on screen to protect.
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

    /// What VoiceOver reads for the overlay: the phase, or just that something is running.
    var accessibilityValue: String {
        phaseLabel ?? tr("Trwa skanowanie")
    }
}

/// A running scan, drawn the same way wherever it is running.
///
/// There are two of those places and they must not diverge: the full-screen scan the user
/// started, and the quiet launch refresh that runs underneath the restored list. They report
/// the identical thing, so they get the identical view — at the identical size. Scaling it
/// down for the overlay was tried and is exactly what made them look like two different
/// screens: Wega shrank, and the binary stream was clipped mid-character by the card holding
/// it. There is no size knob now, so there is nothing to set differently in one of the places.
///
/// The padding belongs to the scene rather than to its callers, for the same reason.
struct ScanProgressScene: View {
    let progress: ScanProgress?

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
            if let phaseLabel = presentation.phaseLabel {
                Text(phaseLabel)
                    .font(.wega(.subheadline, monospaced: true))
                    .foregroundStyle(.tertiary)
            }
            SniffingScene(
                caption: tr("Wega węszy po Homebrew…"),
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
        tr("Sniff sniff… brew outdated"),
        tr("Hmm, znajomy zapach Sparkle"),
        tr("SHA256 się zgadza?"),
        tr("Łapię trop wersji"),
        "0x4A 0x65 0x6C 0x6C 0x79",
        tr("Mhm… nowa wersja?"),
        tr("Info.plist… mhm"),
        tr("Ten cask wymaga odświeżenia")
    ]
}

/// The list a scan is replacing, stood down while the scan runs in place (UX-19).
///
/// The scan itself reports in the header (`ScanPhaseStrip`), so this no longer draws a second
/// scanning scene over the rows: it covers them with a veil of the window's own background,
/// which is what stands them down — one mechanism, not a separate dimming of the list — and
/// says why they cannot be selected, with a spinner and the command the scan is running now.
/// The veil is deliberately translucent: the whole point of scanning in place is that the
/// previous result never leaves the window.
struct ScanBusyOverlay: View {
    let progress: ScanProgress?

    /// How much of the window's background lies over the rows: enough to read as stood down,
    /// little enough that every row stays legible. A material was tried and blurred the rows
    /// into an empty column, so a scan in place looked like a blank, frozen list.
    static let scrimOpacity: Double = 0.5

    private var presentation: ScanBusyPresentation { ScanBusyPresentation(progress: progress) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Zaznaczanie wróci, gdy skan się skończy."))
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                    if let phaseLabel = presentation.phaseLabel {
                        Text(phaseLabel)
                            .font(.wega(.caption, monospaced: true))
                            .foregroundStyle(.tertiary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .padding(24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(Self.scrimOpacity))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Odświeżam listę…"))
        .accessibilityValue(presentation.accessibilityValue)
    }
}
