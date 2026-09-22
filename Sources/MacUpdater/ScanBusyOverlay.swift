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

/// The scan, drawn over the list it is replacing.
///
/// The same scene as the full-screen scan, at the same size and with the same padding, over a
/// material that covers the whole list area. It used to sit in a bordered card at a reduced
/// scale, which read as a different screen rather than as the same scan in a different place.
///
/// The material is what stands the rows down, rather than a separate dimming of the list: one
/// mechanism, so the two cannot be tuned against each other. It is deliberately not opaque —
/// the rows stay faintly visible, because the whole point of the quiet refresh is that the
/// restored result never leaves the window.
///
/// One line is added that the full-screen scan has no need for: selecting is off until the
/// scan lands. A disabled control that does not explain itself reads as a broken one.
struct ScanBusyOverlay: View {
    let progress: ScanProgress?

    private var presentation: ScanBusyPresentation { ScanBusyPresentation(progress: progress) }

    var body: some View {
        VStack(spacing: 4) {
            ScanProgressScene(progress: progress)
            Text(tr("Zaznaczanie wróci, gdy skan się skończy."))
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Odświeżam listę…"))
        .accessibilityValue(presentation.accessibilityValue)
    }
}
