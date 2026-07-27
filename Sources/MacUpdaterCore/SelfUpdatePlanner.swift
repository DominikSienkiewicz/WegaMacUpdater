import Foundation

/// UX-06 — what "Pobierz i zainstaluj" is actually about, decided before the click.
///
/// Wega either hands a verified `.pkg` to the privileged helper for a headless install, or
/// downloads the asset and opens it for the user to finish (mount a `.dmg`, run an installer).
/// The old button labelled both as "download and install", which was a lie for the second.
public enum SelfUpdateAction: Equatable, Sendable {
    /// Helper-driven, headless install of a verified `.pkg`.
    case install(pkg: ReleaseAsset)
    /// Download the asset and hand it to the system installer/mounter the user drives.
    case downloadAndOpen(asset: ReleaseAsset)

    /// The artifact this action downloads, whichever branch it took.
    public var asset: ReleaseAsset {
        switch self {
        case .install(let pkg):         return pkg
        case .downloadAndOpen(let any): return any
        }
    }
}

public enum SelfUpdatePlanner {
    /// SEC-04 — which published asset the self-update is allowed to offer. The **only**
    /// statement of that ordering in the codebase.
    ///
    /// The `.pkg` wins, always, and the privileged helper does not get a vote. It is the
    /// channel Wega can pin end to end: a Gatekeeper *install* assessment **plus** the
    /// Developer Team ID read out of the package signature. The `.dmg` used to be preferred,
    /// which meant the common self-update path was validated by Gatekeeper alone — and
    /// Gatekeeper answers "notarized by *some* Apple developer", not "published by Wega".
    /// It stays as the fallback for releases that ship no package, but it is now pinned too
    /// (`CodeSignatureVerifier`).
    ///
    /// This is a security ordering, not a convenience one, so it is deliberately not
    /// conditioned on what the running installation happens to be capable of. Anything
    /// outside these two channels is refused rather than offered: an artifact Wega cannot
    /// pin to its own Team ID has no publisher guarantee at all, and offering it is strictly
    /// worse than offering nothing.
    public static func preferredAsset(from assets: [ReleaseAsset]) -> ReleaseAsset? {
        assets.first { $0.kind == "pkg" } ?? assets.first { $0.kind == "dmg" }
    }

    /// The single source of truth for the install-vs-open decision, shared by the button label
    /// and the code that performs the operation.
    ///
    /// `helperEnabled` does **not** select the artifact — ``preferredAsset(from:)`` already
    /// did that, on security grounds. It decides only whether the chosen artifact is installed
    /// headlessly or handed to the user to finish. So a `.pkg` is what gets downloaded whether
    /// or not the helper is available; without the helper the user simply runs it themselves.
    ///
    /// Returns `nil` when the release published nothing Wega can verify — the caller renders
    /// no button rather than one that cannot act safely.
    public static func action(helperEnabled: Bool, assets: [ReleaseAsset]) -> SelfUpdateAction? {
        guard let preferred = preferredAsset(from: assets) else { return nil }
        if helperEnabled, preferred.kind == "pkg" { return .install(pkg: preferred) }
        return .downloadAndOpen(asset: preferred)
    }
}
