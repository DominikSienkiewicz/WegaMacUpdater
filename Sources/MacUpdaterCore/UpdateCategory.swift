import Foundation

/// Broad category of an update for sidebar grouping: user-facing apps vs
/// command-line tools. Casks and App Store items are apps; formulae and npm
/// globals are CLI tools.
public enum UpdateCategory: Equatable, Sendable {
    case apps, cli
}

public extension OutdatedItem.Kind {
    var category: UpdateCategory {
        switch self {
        case .cask, .appStore: return .apps
        case .formula, .npm:   return .cli
        }
    }
}
