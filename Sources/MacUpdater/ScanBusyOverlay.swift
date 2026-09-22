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
/// started, and the quiet launch refresh that runs underneath the restored list. They used to
/// look nothing alike — one was Wega sniffing across a binary stream, the other a progress
/// ring — although they report the identical thing. One view now serves both, so the scan has
/// one face and a change to it cannot reach only half the app.
///
/// `size` scales the scene for the overlay; nothing else about it changes.
struct ScanProgressScene: View {
    enum Size {
        case full
        case compact

        var wegaSize: CGFloat { self == .full ? 120 : 84 }
        var sceneHeight: CGFloat { self == .full ? 170 : 124 }
        var topPadding: CGFloat { self == .full ? 16 : 10 }
    }

    let progress: ScanProgress?
    var size: Size = .full

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
                thoughts: Self.scanThoughts,
                wegaSize: size.wegaSize,
                height: size.sceneHeight
            )
            .frame(maxWidth: .infinity)
            .padding(.top, size.topPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
/// The same scene as the full-screen scan, scaled into a card, plus the one thing that screen
/// has no need to say: selecting is off for the duration. A disabled control that does not
/// explain itself reads as a broken one. The list underneath is dimmed by `dimmedListOpacity`
/// and disabled by its caller, so this view draws only the explanation.
struct ScanBusyOverlay: View {
    /// How far the list fades while the scan runs: clearly out of reach, still legible enough
    /// to see that the rows underneath are the ones being replaced.
    static let dimmedListOpacity: Double = 0.45

    let progress: ScanProgress?

    private var presentation: ScanBusyPresentation { ScanBusyPresentation(progress: progress) }

    var body: some View {
        VStack(spacing: 12) {
            ScanProgressScene(progress: progress, size: .compact)
            Text(tr("Zaznaczanie wróci, gdy skan się skończy."))
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: WegaLayout.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: WegaLayout.cardRadius)
                .stroke(Color.wegaHairline, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Odświeżam listę…"))
        .accessibilityValue(presentation.accessibilityValue)
    }
}
