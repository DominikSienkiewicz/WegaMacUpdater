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
    /// would otherwise round the count down to a false "all clear".
    static func finishedQuip(updateCount: Int, securityCount: Int) -> String {
        if securityCount > 0 { return tr("Znalazłam coś pilnego.") }
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

    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 84

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            WegaIcon(size: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(asksForNotifications ? tr("Powiadamiać o nowych aktualizacjach?") : presentation.line)
                    .font(.wega(.callout, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                if asksForNotifications {
                    HStack(spacing: 6) {
                        Button(tr("Nie teraz"), action: onDecline)
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wega")
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
            onAgree: { Task { await agent.agreeToNotifications() } }
        )
        .animation(.easeInOut(duration: 0.2), value: quip)
    }
}
