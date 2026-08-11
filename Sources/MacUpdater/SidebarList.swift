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

    /// `List` must be able to express "no selection"; the window never can. Writes of `nil`
    /// (a deselect click) are dropped so a destination always stays chosen.
    private var listSelection: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: { if let new = $0 { selection = new } }
        )
    }

    var body: some View {
        List(selection: listSelection) {
            Section {
                row(.updates(.all),      badge: appsBadge + cliBadge, spins: true)
                row(.updates(.apps),     badge: appsBadge)
                row(.updates(.cli),      badge: cliBadge)
                row(.updates(.security), badge: securityBadge, isDanger: true)
            } header: { header(tr("Do aktualizacji")) }
            Section {
                row(.migration)
                row(.inventory)
            } header: { header(tr("Zainstalowane")) }
            Section {
                row(.rollback, badge: rollbackBadge)
                row(.uninstall)
                row(.logs, badge: logsErrorBadge, isDanger: true)
            } header: { header(tr("Narzędzia")) }
        }
        .listStyle(.sidebar)
        // On this SDK the sidebar `List` renders with almost no leading inset, so its rows'
        // icons touch the window's left edge. Keep this padding fixed: making it depend on scan
        // activity changes NSSplitView geometry during a safe-area update and can create an
        // unbounded AppKit constraints loop. Sticky headers need their own matching inset.
        .safeAreaPadding(.leading, 18)
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
        let status = ScanStatusAccessibilitySemantics(activity: activity, baseSymbol: item.systemImage)
        Label {
            Text(item.label)
        } icon: {
            SidebarRowIcon(
                systemImage: status.symbolName,
                activity:    activity,
                isActive:    selection == item
            )
        }
        .badge(count > 0 ? Text(badgeText(count, isDanger: isDanger)) : Text?.none)
        .tag(item)
        .accessibilitySortPriority(SidebarFocusPolicy.accessibilityPriority(for: item))
        .accessibilityValue(status.accessibilityValue ?? "")
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
        case .scanning: return .wegaHoney
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
        if activity == .scanning && !reduceMotion, let spinAnimation {
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
