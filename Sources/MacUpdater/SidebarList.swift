import SwiftUI
import MacUpdaterCore

enum SidebarFocusPolicy {
    /// Reading order for assistive technology, taken from `SidebarSelection.allCases` so a
    /// new destination cannot reach the sidebar with an unset priority.
    static let orderedSelections: [SidebarSelection] = SidebarSelection.allCases

    static func accessibilityPriority(for selection: SidebarSelection) -> Double {
        guard let index = orderedSelections.firstIndex(of: selection) else { return 0 }
        return Double(orderedSelections.count - index)
    }
}

/// The glass sidebar. `NavigationSplitView` supplies the material, the selection capsule and
/// the hover fill; the hand-rolled `SidebarItemRow` that used to draw them is gone.
struct SidebarList: View {
    @Binding var selection: SidebarSelection
    let appsBadge:      Int
    let cliBadge:       Int
    let securityBadge:  Int
    let logsErrorBadge: Int
    /// How many committed updates still have a retained snapshot — a possibility, not an
    /// alarm, so it is badged in caramel like the update counts rather than in danger red.
    let rollbackBadge:  Int
    let updateActivity: UpdateActivity
    /// UXP-09 — how far the running update has got, shown as "done/total" in the Updates badge.
    var updateProgress: UpgradeProgress?
    /// UX-15 — what Wega's card at the bottom of the sidebar says and comments on.
    let wegaState:      WegaState
    let lastCheck:      Date?
    let quip:           String?
    /// UXP-27 — worked out by `DetailColumn`; while it holds, the card's ball waits.
    var wegaAttentionHeld: Bool = false

    /// `List` must be able to express "no selection"; the window never can. Writes of `nil`
    /// (a deselect click) are dropped so a destination always stays chosen. UX-16 — every
    /// filtered Updates list highlights the one Updates row, and picking that row while
    /// already on Updates keeps the scope chosen above the list.
    private var listSelection: Binding<SidebarSelection?> {
        Binding(
            get: { selection.sidebarRow },
            set: { if let new = $0 { selection = selection.applyingSidebarPick(new) } }
        )
    }

    var body: some View {
        List(selection: listSelection) {
            // UX-16 — one row; the categories are the scope bar above the list. The badge
            // turns red while a security fix is waiting, which its own row used to say.
            Section {
                row(.updates(.all), badge: appsBadge + cliBadge, isDanger: securityBadge > 0, spins: true)
            } header: { header(tr("Do aktualizacji")) }
            Section {
                row(.migration)
                row(.inventory)
            } header: { header(tr("Zainstalowane")) }
            Section {
                row(.rollback, badge: rollbackBadge)
                row(.uninstall)
                row(.cleanup)
                row(.logs, badge: logsErrorBadge, isDanger: true)
            } header: { header(tr("Narzędzia")) }
        }
        .listStyle(.sidebar)
        // On this SDK the sidebar `List` renders with almost no leading inset, so its rows'
        // icons touch the window's left edge. Keep this padding fixed: making it depend on scan
        // activity changes NSSplitView geometry during a safe-area update and can create an
        // unbounded AppKit constraints loop. Sticky headers need their own matching inset.
        .safeAreaPadding(.leading, 18)
        // UX-15 — Wega's card. Its height is fixed (see `WegaCompanionCardContent`), so this
        // inset is the same before, during and after a scan.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WegaCompanionCard(state: wegaState, lastCheck: lastCheck, quip: quip, attentionHeld: wegaAttentionHeld)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    /// A section header carrying the same leading inset the rows get from `safeAreaPadding`,
    /// which does not reach sticky headers on this SDK.
    private func header(_ title: String) -> some View {
        Text(title).padding(.leading, 18)
    }

    @ViewBuilder
    private func row(
        _ item: SidebarSelection,
        badge count: Int = 0,
        isDanger: Bool = false,
        spins: Bool = false
    ) -> some View {
        let activity: UpdateActivity = spins ? updateActivity : .idle
        let status = ScanStatusAccessibilitySemantics(
            activity: activity, baseSymbol: item.systemImage, progress: spins ? updateProgress : nil
        )
        Label {
            Text(item.label)
        } icon: {
            SidebarRowIcon(
                systemImage: status.symbolName,
                activity:    activity,
                isActive:    selection == item
            )
        }
        .badge(badge(count: count, isDanger: isDanger, activity: activity))
        .tag(item)
        .accessibilitySortPriority(SidebarFocusPolicy.accessibilityPriority(for: item))
        .accessibilityValue(status.accessibilityValue ?? "")
    }

    private func badge(count: Int, isDanger: Bool, activity: UpdateActivity) -> Text? {
        if activity == .updating, let run = updateProgress {
            return Text(runBadgeText(run))
        }
        return count > 0 ? Text(badgeText(count, isDanger: isDanger)) : nil
    }

    private func runBadgeText(_ run: UpgradeProgress) -> AttributedString {
        var text = AttributedString("\(run.completedUnits)/\(run.totalUnits)")
        text.foregroundColor = .wegaCaramel
        return text
    }

    private func badgeText(_ count: Int, isDanger: Bool) -> AttributedString {
        var text = AttributedString("\(count)")
        text.foregroundColor = isDanger ? .wegaDanger : .wegaCaramel
        return text
    }
}

/// The Updates icon spins while a scan runs, turns green when it finishes cleanly and red when
/// a source failed. Lifted verbatim from the deleted `SidebarItemRow`.
private struct SidebarRowIcon: View {
    let systemImage: String
    let activity:    UpdateActivity
    let isActive:    Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation: Double = 0

    private var iconColor: Color {
        switch activity {
        case .scanning, .updating: return .wegaHoney
        case .success:  return .wegaSuccess
        case .error:    return .wegaDanger
        case .idle:     return isActive ? .wegaHoney : .secondary
        }
    }

    /// Continuous spin while scanning; ease back to rest otherwise. UX-03 routes the endless
    /// half through `ContinuousMotion`, so every never-ending animation in the app answers
    /// "Ogranicz ruch" through one policy rather than one condition per view.
    private func spin(for activity: UpdateActivity) {
        let spinAnimation = ContinuousMotion.forever(
            .linear(duration: 1),
            autoreverses: false,
            reduceMotion: reduceMotion
        )
        if activity.spinsContinuously && !reduceMotion, let spinAnimation {
            withAnimation(spinAnimation) { rotation = 360 }
        } else {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { rotation = 0 }
        }
    }

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(iconColor)
            .rotationEffect(.degrees(rotation))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: iconColor)
            .onChange(of: activity) { _, new in spin(for: new) }
            .onChange(of: reduceMotion) { _, _ in spin(for: activity) }
            .onAppear { spin(for: activity) }
    }
}
