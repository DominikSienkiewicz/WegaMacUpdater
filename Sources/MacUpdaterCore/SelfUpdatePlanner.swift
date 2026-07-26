import Foundation

/// UX-06 — what "Pobierz i zainstaluj" is actually about, decided before the click.
///
/// Wega either hands a verified `.pkg` to the privileged helper for a headless install, or
/// downloads the asset and opens it for the user to finish (mount a `.dmg`, run an installer).
/// The old button labelled both as "download and install", which was a lie for the second —
/// the common case, since the checker prefers the drag-to-Applications `.dmg`.
public enum SelfUpdateAction: Equatable, Sendable {
    /// Helper-driven, headless install of a verified `.pkg`.
    case install
    /// Download the asset and hand it to the system installer/mounter the user drives.
    case downloadAndOpen
}

public enum SelfUpdatePlanner {
    /// The single source of truth for the install-vs-open decision, shared by the button
    /// label and the code that performs the operation so the two can never disagree.
    public static func action(helperEnabled: Bool, assetURL: URL) -> SelfUpdateAction {
        let isPackage = assetURL.pathExtension.lowercased() == "pkg"
        return (helperEnabled && isPackage) ? .install : .downloadAndOpen
    }
}
