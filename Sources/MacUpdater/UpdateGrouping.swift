import Foundation
import MacUpdaterCore

/// UX-18 — how the Updates list is grouped. By urgency is the default the owner chose; by
/// source is the grouping the Inventory window shares, one menu choice away.
enum UpdateGrouping: String, CaseIterable {
    case urgency, source

    static let storageKey = "wega.updates.grouping"
    static let `default`: UpdateGrouping = .urgency

    var title: String {
        switch self {
        case .urgency: return tr("według pilności")
        case .source:  return tr("według źródła")
        }
    }
}

/// UX-18 — the Updates list grouped by what the user does next.
///
/// "Possible security fixes" uses the very definition the scope bar's security scope uses —
/// manually updated apps whose release notes read as a security fix — so the group and the
/// scope can never disagree about what is urgent.
struct UrgencyGroups: Equatable {
    /// Possible security fixes, which the vendor's updater or the user installs.
    let security: [ManualOutdatedApp]
    /// Apps Wega updates in a batch: casks and Mac App Store apps.
    let apps: [OutdatedItem]
    /// Command-line tools Wega updates in a batch: formulae and global npm packages.
    let cli: [OutdatedItem]
    /// Everything else the vendor's updater or the user has to finish.
    let needsYou: [ManualOutdatedApp]

    /// The four groups, in the order they appear on screen.
    enum Kind: CaseIterable { case security, apps, cli, needsYou }

    /// The 1-based position of a group among the non-empty ones, or nil for an empty group.
    func ordinal(of kind: Kind) -> Int? {
        let present = Kind.allCases.filter { !isEmpty($0) }
        return present.firstIndex(of: kind).map { $0 + 1 }
    }

    private func isEmpty(_ kind: Kind) -> Bool {
        switch kind {
        case .security: return security.isEmpty
        case .apps:     return apps.isEmpty
        case .cli:      return cli.isEmpty
        case .needsYou: return needsYou.isEmpty
        }
    }

    /// Splits the lists, keeping their order, and applies the scope bar's filter: grouping
    /// decides the order on screen, never what is on it.
    static func make(
        items: [OutdatedItem],
        manual: [ManualOutdatedApp],
        filter: UpdateFilter,
        isSecurity: (ManualOutdatedApp) -> Bool
    ) -> UrgencyGroups {
        let security = manual.filter(isSecurity)
        let rest = manual.filter { !isSecurity($0) }
        let apps = items.filter { $0.kind.category == .apps }
        let cli = items.filter { $0.kind.category == .cli }
        switch filter {
        case .all:      return UrgencyGroups(security: security, apps: apps, cli: cli, needsYou: rest)
        case .apps:     return UrgencyGroups(security: security, apps: apps, cli: [], needsYou: rest)
        case .cli:      return UrgencyGroups(security: [], apps: [], cli: cli, needsYou: [])
        case .security: return UrgencyGroups(security: security, apps: [], cli: [], needsYou: [])
        }
    }
}

extension OutdatedItem.Kind {
    /// Names the source on the row itself, where grouping by urgency mixes sources in a card.
    var sourceLabel: String {
        switch self {
        case .cask:     return tr("Aplikacja Homebrew")
        case .formula:  return tr("Narzędzie Homebrew")
        case .appStore: return tr("Mac App Store")
        case .npm:      return tr("npm (globalny)")
        }
    }
}
