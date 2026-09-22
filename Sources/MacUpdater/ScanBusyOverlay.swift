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

/// What the busy overlay knows about the scan running underneath the list.
///
/// A phase the scan has not reported yet is `nil` rather than zero: between the refresh flag
/// going up and the first phase landing, and after a finished run leaves `.finished` standing,
/// a ring drawn from `ScanProgress.fractionCompleted` would claim a position the scan has not
/// taken. Unknown draws a plain spinner — the one place an indeterminate indicator is the
/// honest one.
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

    /// The ring's own caption, rounded to whole percent. `nil` alongside `fraction`.
    var percentLabel: String? {
        guard let fraction else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// What VoiceOver reads for the overlay: the phase and the position, or just the fact
    /// that something is running when neither is known yet.
    var accessibilityValue: String {
        switch (percentLabel, phaseLabel) {
        // A command name and a percentage, joined by a dash: nothing here is language-
        // specific, so it is interpolated rather than routed through a translation key.
        case (let percent?, let phase?): return "\(phase) — \(percent)"
        case (let percent?, nil):        return percent
        case (nil, let phase?):          return phase
        case (nil, nil):                 return tr("Trwa skanowanie")
        }
    }
}

/// The scan, drawn over the list it is replacing.
///
/// The card names the phase and shows how far the scan has got, and says out loud that
/// selecting is off for the duration — a disabled control that does not explain itself reads
/// as a broken one. The list underneath is dimmed by `dimmedListOpacity` and disabled by its
/// caller, so this view draws only the explanation.
///
/// The ring carries two separate signals, and it is worth keeping them apart: the *fill* is
/// the scan's real position and moves only at a phase boundary, while the slow *turn* means
/// nothing beyond "still running" — see `spin()` for why the fill alone is not enough.
struct ScanBusyOverlay: View {
    /// How far the list fades while the scan runs: clearly out of reach, still legible enough
    /// to see that the rows underneath are the ones being replaced.
    static let dimmedListOpacity: Double = 0.45

    let presentation: ScanBusyPresentation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation: Double = 0

    private let ringSize: CGFloat  = 64
    private let ringWidth: CGFloat = 6
    /// One turn per this many seconds. Slow on purpose: the rotation is there to say the scan
    /// is alive, and anything brisk enough to read as speed would compete with the fill, which
    /// is the half that actually means something.
    private let turnDuration: Double = 6

    var body: some View {
        VStack(spacing: 12) {
            indicator
            VStack(spacing: 4) {
                Text(tr("Odświeżam listę…"))
                    .font(.wega(.callout, weight: .semibold))
                if let phaseLabel = presentation.phaseLabel {
                    Text(phaseLabel)
                        .font(.wega(.subheadline, monospaced: true))
                        .foregroundStyle(.tertiary)
                }
                Text(tr("Zaznaczanie wróci, gdy skan się skończy."))
                    .font(.wega(.subheadline))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: WegaLayout.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: WegaLayout.cardRadius)
                .stroke(Color.wegaHairline, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Odświeżam listę…"))
        .accessibilityValue(presentation.accessibilityValue)
    }

    @ViewBuilder
    private var indicator: some View {
        if let fraction = presentation.fraction {
            ZStack {
                ZStack {
                    Circle()
                        .stroke(Color.wegaHairline, lineWidth: ringWidth)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(
                            Color.wegaHoney,
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                        )
                        // `trim` starts at three o'clock; a progress ring starts at twelve.
                        .rotationEffect(.degrees(-90))
                }
                // A phase boundary is a jump of a quarter turn. Easing it reads as progress
                // rather than as a redraw; "Ogranicz ruch" takes the jump instead.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: fraction)
                // Applied outside that scope, so the endless turn and the fill do not animate
                // each other: the fill is driven by `fraction`, the turn by `withAnimation`.
                .rotationEffect(.degrees(rotation))

                // Deliberately outside the rotating stack — a spinning percentage would be
                // unreadable, and it is the one part of the ring that carries a number.
                if let percentLabel = presentation.percentLabel {
                    Text(percentLabel)
                        .font(.wega(.subheadline, monospaced: true))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: ringSize, height: ringSize)
            .onAppear { spin() }
            .onChange(of: reduceMotion) { _, _ in spin() }
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(width: ringSize, height: ringSize)
        }
    }

    /// The ring's endless half. Brew — the first of four phases — is also the longest, so a
    /// ring driven by progress alone sits at 0% for most of a scan and reads as frozen. The
    /// turn says "still running" where the fill has nothing yet to say.
    ///
    /// UX-03 routes it through `ContinuousMotion`, the one place that answers "Ogranicz ruch"
    /// for every never-ending animation in the app: under that setting the ring simply holds
    /// still, because a loop with no end cannot be shortened, only not started.
    private func spin() {
        guard
            ContinuousMotion.loopsIdleAnimations(reduceMotion: reduceMotion),
            let turn = ContinuousMotion.forever(
                .linear(duration: turnDuration),
                autoreverses: false,
                reduceMotion: reduceMotion
            )
        else {
            withAnimation(nil) { rotation = 0 }
            return
        }
        // Restart from rest, so toggling the setting back on does not resume mid-turn from a
        // value the held frame never showed.
        rotation = 0
        withAnimation(turn) { rotation = 360 }
    }
}
