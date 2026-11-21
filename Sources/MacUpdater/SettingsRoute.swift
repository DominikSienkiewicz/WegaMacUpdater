import SwiftUI
import MacUpdaterCore

/// The five categories of the Settings window, in the order the window shows them (UXP-15).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, checking, permissions, cleanup, advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general:     tr("Ogólne")
        case .checking:    tr("Sprawdzanie i tło")
        case .permissions: tr("Uprawnienia i prywatność")
        case .cleanup:     tr("Porządki")
        case .advanced:    tr("Zaawansowane")
        }
    }

    var systemImage: String {
        switch self {
        case .general:     "gearshape"
        case .checking:    "arrow.triangle.2.circlepath"
        case .permissions: "lock.shield"
        case .cleanup:     "sparkles"
        case .advanced:    "slider.horizontal.3"
        }
    }
}

/// A Settings card another screen can send the user to. Each one is the scroll target
/// `.id(SettingsCard.…)` on its card.
enum SettingsCard: String {
    case selfUpdate, policies, trust, helper, touchID

    /// The tab that holds the card.
    var tab: SettingsTab {
        switch self {
        case .selfUpdate:               .general
        case .policies:                 .checking
        case .trust, .helper, .touchID: .permissions
        }
    }
}

/// Which Settings tab is showing, and which card a banner, a menu item or a row asked for.
///
/// One shared instance, because the asking happens in the main window and the cards live in the
/// separate Settings scene; the tab it remembers survives the window closing and the language
/// changing.
@MainActor
final class SettingsRoute: ObservableObject {
    static let shared = SettingsRoute()

    @Published var tab: SettingsTab = .general
    @Published private(set) var focusedCard: SettingsCard?

    /// Tests make their own instance; the app uses `shared`.
    init() {}

    /// Selects the card's tab and leaves the card for that tab's page to scroll to.
    func show(_ card: SettingsCard) {
        tab = card.tab
        focusedCard = card
    }

    /// The card the page of `tab` should scroll to, handed out once.
    ///
    /// Only the card's own page takes it: when the route switches tabs, the page being left still
    /// hears the change after it has disappeared, and taking the card there would open the new page
    /// at its top.
    func consumeFocus(on tab: SettingsTab) -> SettingsCard? {
        guard let card = focusedCard, card.tab == tab else { return nil }
        focusedCard = nil
        return card
    }

    /// Opens the Settings window at `card`.
    func open(_ card: SettingsCard, with openSettings: OpenSettingsAction) {
        show(card)
        openSettings()
    }
}
