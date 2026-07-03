import Foundation

/// The origin family an outdated app's update comes from. UI-agnostic (no colour)
/// so it stays in Core and is unit-tested; the view maps it to a badge colour.
public enum Provenance: Equatable, Sendable {
    case homebrew, appStore, jetbrains, github, sparkle, synology, vendorDirect
}

public extension ManualOutdatedApp.UpdateSource {
    /// Groups a concrete update source into a provenance family for consistent
    /// colour-coding. The self-updating vendor apps (which ship their own updater
    /// while their Homebrew cask lags) all share `.vendorDirect`.
    var provenance: Provenance {
        switch self {
        case .cask:       return .homebrew
        case .mas:        return .appStore
        case .jetbrains:  return .jetbrains
        case .github:     return .github
        case .sparkle:    return .sparkle
        case .synology:   return .synology
        case .antigravity, .parallels, .googleDrive, .chatgpt, .postman, .discord, .signal, .chrome:
            return .vendorDirect
        }
    }
}
