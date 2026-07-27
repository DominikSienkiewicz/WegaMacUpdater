import Foundation

/// The update action for one source, expressed as data (ARCH-06 — "akcje jako dane w
/// Core, a nie jako gałęzie `switch` w UI").
///
/// The Updates window renders a fixed vocabulary of action kinds; a source maps to a kind
/// here, in Core, instead of growing another per-vendor branch in the view. The nine
/// self-updating vendors that used to be nine identical `switch` cases now all resolve to
/// the single `.launchApp`, so a new one needs no UI change at all.
public enum UpdateActionKind: Equatable, Sendable {
    /// Launch the app so its own updater applies the staged build. Shared by every vendor
    /// that self-updates while its Homebrew cask lags (Sparkle, ChatGPT, Discord, …).
    case launchApp
    /// Update through Homebrew, with a busy indicator while the install runs.
    case brewInstall(token: String)
    /// App Store apps update themselves; the row shows text, not a button.
    case appStore
    /// Open a vendor page/download URL. The URL is `nil` when it could not be built, in
    /// which case the control is inert (matching the pre-refactor `if let url` guards).
    case openURL(URL?, style: OpenURLStyle)
    /// Open JetBrains Toolbox, resolved on disk at tap time.
    case jetBrainsToolbox
    /// Wega's own update. The row opens the Settings self-update screen, which owns the
    /// download, the signature verification, the helper install and the restart; `releaseURL`
    /// is carried for the secondary "see the release" link.
    case openSelfUpdate(releaseURL: URL)
}

/// Which labelled variant of the "open a URL" action a source uses. The label text stays
/// in the UI (it is localized via `tr`); this only tells the view which one to render.
public enum OpenURLStyle: Equatable, Sendable {
    case githubReleases
    case synologyDownload
    case vendorDownload
}

public extension ManualOutdatedApp.UpdateSource {
    /// The badge text shown next to the action — brand name for self-updating vendors, the
    /// concrete token/id for the sources that carry one. Single source of truth for both the
    /// list row and the inspector pane.
    var badgeLabel: String {
        switch self {
        case .sparkle:              return "Sparkle"
        case .cask(let token):      return token
        case .mas(let appStoreID):  return appStoreID
        case .jetbrains(let token): return token
        case .github:               return "GitHub"
        case .synology:             return "Synology"
        case .antigravity:          return "Antigravity"
        case .parallels:            return "Parallels"
        case .googleDrive:          return "Google Drive"
        case .chatgpt:              return "ChatGPT"
        case .postman:              return "Postman"
        case .discord:              return "Discord"
        case .signal:               return "Signal"
        case .chrome:               return "Chrome"
        case .obsidian:             return "Obsidian"
        case .wega:                 return "Wega"
        }
    }

    /// The Updates-window action for this source, as data. The view switches on the small,
    /// fixed set of `UpdateActionKind`s rather than on the source itself.
    var updateActionKind: UpdateActionKind {
        switch self {
        case .cask(let token):
            return .brewInstall(token: token)
        case .mas:
            return .appStore
        case .github(let repo):
            return .openURL(AppEndpoints.shared.githubReleasesPageURL(repo: repo), style: .githubReleases)
        case .jetbrains:
            return .jetBrainsToolbox
        case .synology(let downloadPage):
            return .openURL(URL(string: downloadPage), style: .synologyDownload)
        case .googleDrive:
            return .openURL(AppEndpoints.shared.googleDriveDownloadURL, style: .vendorDownload)
        case .wega(let releaseURL):
            // "Launching the app" would be Wega itself and would apply nothing; the browser
            // would step around signature verification and the helper install. So the row
            // leads to the in-app installer.
            return .openSelfUpdate(releaseURL: releaseURL)
        case .sparkle, .antigravity, .parallels, .chatgpt, .postman, .discord, .signal, .chrome, .obsidian:
            return .launchApp
        }
    }
}
