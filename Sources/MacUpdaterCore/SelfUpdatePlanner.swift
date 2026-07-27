import Foundation

/// UX-06 — what "Pobierz i zainstaluj" is actually about, decided before the click.
///
/// Wega either hands a verified `.pkg` to the privileged helper for a headless install, or
/// downloads the asset and opens it for the user to finish (mount a `.dmg`, run an installer).
/// The old button labelled both as "download and install", which was a lie for the second.
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

    /// SEC-04 — which published asset the self-update is allowed to prefer.
    ///
    /// The `.pkg` wins. It is the channel Wega can pin end to end: a Gatekeeper *install*
    /// assessment **plus** the Developer Team ID read out of the package signature, and with
    /// the privileged helper enabled it installs headlessly without ever handing an opaque
    /// artifact to `NSWorkspace`. The `.dmg` used to be preferred, which meant the common
    /// self-update path was validated by Gatekeeper alone — and Gatekeeper answers "notarized
    /// by *some* Apple developer", not "published by Wega". It stays as the fallback for
    /// releases that ship no package, but it is now pinned too (`CodeSignatureVerifier`).
    ///
    /// Pure string work over asset names so the preference can be unit-tested without a
    /// network round trip.
    public static func preferredAssetName(from names: [String]) -> String? {
        names.first { $0.lowercased().hasSuffix(".pkg") }
            ?? names.first { $0.lowercased().hasSuffix(".dmg") }
    }
}
