import Foundation

extension RollbackProtection {
    /// The scope of an app snapshot, not evidence that a snapshot exists or was verified.
    public enum Scope: Equatable, Sendable {
        case appBundleOnly
        /// Docker settings, VM, volumes and container data are outside the app bundle.
        case dockerAppBundleOnly
    }

    public static func scope(token: String) -> Scope {
        let shortToken = token.split(separator: "/").last.map(String.init) ?? token
        return shortToken == "docker" || shortToken == "docker-desktop"
            ? .dockerAppBundleOnly : .appBundleOnly
    }
}

extension UndoableUpdate {
    public var rollbackScope: RollbackProtection.Scope {
        RollbackProtection.scope(token: token)
    }
}
