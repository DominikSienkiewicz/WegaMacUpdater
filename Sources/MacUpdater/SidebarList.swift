import SwiftUI
import MacUpdaterCore

/// The glass sidebar. `NavigationSplitView` supplies the material, the selection capsule and
/// the hover fill; the hand-rolled `SidebarItemRow` that used to draw them is gone.
struct SidebarList: View {
    @Binding var selection: SidebarSelection
    let appsBadge:      Int
    let cliBadge:       Int
    let securityBadge:  Int
    let logsErrorBadge: Int
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
            Section(tr("Do aktualizacji")) {
                row(.updates(.all),      badge: appsBadge + cliBadge, spins: true)
                row(.updates(.apps),     badge: appsBadge)
                row(.updates(.cli),      badge: cliBadge)
                row(.updates(.security), badge: securityBadge, isDanger: true)
            }
            Section(tr("Zainstalowane")) {
                row(.migration)
                row(.inventory)
            }
            Section(tr("Narzędzia")) {
                row(.uninstall)
                row(.logs, badge: logsErrorBadge, isDanger: true)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(
        _ item: SidebarSelection,
        badge count: Int = 0,
        isDanger: Bool = false,
        spins: Bool = false
    ) -> some View {
        Label {
            Text(item.label)
        } icon: {
            SidebarRowIcon(
                systemImage: item.systemImage,
                activity:    spins ? updateActivity : .idle,
                isActive:    selection == item
            )
        }
        .badge(count > 0 ? Text(badgeText(count, isDanger: isDanger)) : Text?.none)
        .tag(item)
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

    @State private var rotation: Double = 0

    private var iconColor: Color {
        switch activity {
        case .scanning: return .wegaHoney
        case .success:  return .wegaSuccess
        case .error:    return .wegaDanger
        case .idle:     return isActive ? .wegaHoney : .secondary
        }
    }

    /// Continuous spin while scanning; ease back to rest otherwise.
    private func spin(for activity: UpdateActivity) {
        if activity == .scanning {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { rotation = 360 }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { rotation = 0 }
        }
    }

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(iconColor)
            .rotationEffect(.degrees(rotation))
            .animation(.easeInOut(duration: 0.25), value: iconColor)
            .onChange(of: activity) { _, new in spin(for: new) }
            .onAppear { spin(for: activity) }
    }
}
