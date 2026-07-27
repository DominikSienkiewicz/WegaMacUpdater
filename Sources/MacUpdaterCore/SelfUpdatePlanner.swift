import Foundation

/// UX-06 — what the self-update button is actually about, decided before the click.
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
    /// The single source of truth for the install-vs-open decision, shared by the button label
    /// and the code that performs the operation.
    ///
    /// Returns `nil` when the release published nothing usable — the caller renders no button
    /// rather than one that cannot act.
    public static func action(helperEnabled: Bool, assets: [ReleaseAsset]) -> SelfUpdateAction? {
        let package = assets.first { $0.kind == "pkg" }
        if helperEnabled, let package { return .install(pkg: package) }

        guard let openable = assets.first(where: { $0.kind == "dmg" }) ?? package ?? assets.first else {
            return nil
        }
        return .downloadAndOpen(asset: openable)
    }
}
