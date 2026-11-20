import SwiftUI

// MARK: - Presentation (UX-15)

/// What Wega's sidebar card says: her line for the current destination, or a fresher comment
/// on a scan that just finished, and when she last looked.
///
/// The update and security counts are deliberately absent: they are the sidebar's own
/// badges, and the footer that used to repeat them under every tab is gone.
struct WegaCompanionPresentation: Equatable {
    let line: String
    let freshness: String

    init(state: WegaState, quip: String?, lastCheck: Date?) {
        line = quip ?? state.line
        if let lastCheck {
            freshness = trf("Sprawdzono %@", "\(lastCheck.formatted(date: .omitted, time: .shortened))")
        } else {
            freshness = tr("Jeszcze nie sprawdzano")
        }
    }

    /// Wega comments on the result, not on the clock. Security wins over the update count: a
    /// pending security fix still gets flagged even when it happens to be the only item, which
    /// would otherwise round the count down to a false "all clear". An incomplete scan never claims
    /// one either: a source that stayed quiet may be hiding more.
    static func finishedQuip(updateCount: Int, securityCount: Int, scanComplete: Bool) -> String {
        if securityCount > 0 { return trp("Notatki %@ wydań wspominają o bezpieczeństwie.", securityCount) }
        if !scanComplete { return tr("Część źródeł milczy — nie wiem, czy to wszystko.") }
        if updateCount == 0 { return tr("Wszystko pod kontrolą!") }
        return tr("Hau! Nowe paczki?")
    }
}

// MARK: - Card content

/// The card's drawing, free of the stores it reads, so its geometry can be pinned in a test.
///
/// Its height is fixed (scaled only by the system text size): the card sits in the sidebar's
/// safe area, and a sidebar whose geometry changed during a scan once sent AppKit into an
/// unbounded constraint loop (see `SidebarList`). What it says never moves the sidebar.
struct WegaCompanionCardContent: View {
    let presentation: WegaCompanionPresentation
    var asksForNotifications = false
    var onDecline: () -> Void = {}
    var onAgree: () -> Void = {}
    /// UX-17 — only the live card in the sidebar plays the ball chase; a measured or
    /// previewed card stays still.
    var playsWithBall = false

    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 84
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // UX-17 — the card is the stage: the ball rolls along its bottom edge, and Wega runs off
    // its right edge and back in from the left. Offsets and rotation only, clipped to the
    // card, so the card's geometry never moves.
    @State private var stageWidth: CGFloat = 220
    @State private var iconOffset: CGFloat = 0
    @State private var iconRotation: Double = 0
    @State private var ballVisible = false
    @State private var ballX: CGFloat = 0
    @State private var ballAngle: Double = 0
    @State private var carriesBall = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            WegaIcon(size: 36)
                .overlay(alignment: .bottomTrailing) {
                    if carriesBall {
                        WegaBall(diameter: 11).offset(x: 4, y: 3)
                    }
                }
                .rotationEffect(.degrees(iconRotation))
                .offset(x: iconOffset)
                .zIndex(1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(asksForNotifications ? tr("Powiadamiać o nowych aktualizacjach?") : presentation.line)
                    .font(.wega(.callout, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                if asksForNotifications {
                    HStack(spacing: 6) {
                        Button(tr("Nie włączaj powiadomień"), action: onDecline)
                            .help(tr("Możesz je włączyć później w Ustawieniach Wegi."))
                        Button(tr("Powiadamiaj"), action: onAgree)
                            .buttonStyle(.borderedProminent)
                            .tint(Color.wegaHoneyFill)
                            .foregroundStyle(Color.wegaInk)
                            .help(tr("Wega sprawdza w tle i może dać znać, gdy pojawi się coś nowego. macOS zapyta o zgodę tylko raz."))
                    }
                    .controlSize(.small)
                } else {
                    Text(presentation.freshness)
                        .font(.wega(.footnote))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: cardHeight)
        .overlay(alignment: .bottomLeading) {
            if ballVisible {
                WegaBall(diameter: 10)
                    .rotationEffect(.degrees(ballAngle))
                    .offset(x: ballX, y: -5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stageWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wega")
        // Restarted whenever what may play changes, so a stale loop never chases over the
        // notification question or after "Ogranicz ruch" is switched on.
        .task(id: [playsWithBall, asksForNotifications, reduceMotion]) { await playLoop() }
    }

    private func playLoop() async {
        resetStage()
        guard ContinuousMotion.loopsIdleAnimations(reduceMotion: reduceMotion) else { return }
        try? await Task.sleep(for: .seconds(8))
        while !Task.isCancelled {
            await chase()
            try? await Task.sleep(for: .seconds(Double.random(in: 45...90)))
        }
    }

    /// The ball rolls along the card from left to right; Wega glances after it once it has
    /// passed her, runs off the right edge, and comes back in from the left carrying it.
    private func chase() async {
        guard playsWithBall, !asksForNotifications else { return }
        let chase = BallChase(direction: 1, span: stageWidth)
        withAnimation(nil) { ballX = -12; ballAngle = 0; ballVisible = true }
        withAnimation(.linear(duration: BallChase.ballFlight)) { ballX = stageWidth + 12; ballAngle = chase.ballSpin }
        try? await Task.sleep(for: .seconds(BallChase.glanceDelay))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { iconRotation = chase.glanceRotation }
        try? await Task.sleep(for: .seconds(BallChase.glanceHold))
        withAnimation(.easeIn(duration: BallChase.run)) { iconOffset = chase.runOut }
        try? await Task.sleep(for: .seconds(BallChase.run))
        guard !Task.isCancelled else { return }
        withAnimation(nil) { ballVisible = false; iconOffset = chase.reentry; iconRotation = 0; carriesBall = true }
        withAnimation(.easeOut(duration: BallChase.comeBack)) { iconOffset = 0 }
        try? await Task.sleep(for: .seconds(BallChase.comeBack + BallChase.proud))
        withAnimation(.easeOut(duration: 0.3)) { carriesBall = false }
    }

    private func resetStage() {
        withAnimation(nil) {
            iconOffset = 0; iconRotation = 0; ballVisible = false; carriesBall = false
        }
    }
}

// MARK: - Card

/// UX-15 — Wega's place in the window: the bottom of the sidebar, on every destination. It
/// replaced the speech bubble that popped over the list for 4.5 s, the status footer under
/// every tab and the notification strip above the content, and it finally shows the
/// `WegaState.line` each destination has always computed.
///
/// The comment on a finished scan is worked out by `DetailColumn`, which already observes the
/// scan; the card only shows it, so neither it nor the window's root watches a running scan.
struct WegaCompanionCard: View {
    let state: WegaState
    let lastCheck: Date?
    let quip: String?

    @ObservedObject private var agent = MenuBarAgent.shared

    var body: some View {
        WegaCompanionCardContent(
            presentation: WegaCompanionPresentation(state: state, quip: quip, lastCheck: lastCheck),
            asksForNotifications: agent.needsNotificationExplanation,
            onDecline: { agent.declineNotifications() },
            onAgree: { Task { await agent.agreeToNotifications() } },
            playsWithBall: true
        )
        .animation(.easeInOut(duration: 0.2), value: quip)
    }
}
