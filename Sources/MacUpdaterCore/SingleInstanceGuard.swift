/// REL-08 — refuses to run a second copy of Wega.
///
/// `UpgradeMutex` and the `OperationCoordinator` serialise every mutation *within* one
/// process, but neither can see a second process. Two instances launched at once would
/// each drive `brew` and race for its lock — the same half-written Caskroom the shared
/// coordinator exists to prevent. The guard closes that gap at launch.
///
/// The decision is a pure function of how many *other* instances already run, so it is
/// testable without a second process; the AppKit enumeration and the terminate live in
/// the app target's delegate.
public enum SingleInstanceGuard {
    public enum Decision: Equatable, Sendable {
        /// No other instance is running — this launch owns the Homebrew prefix.
        case proceed
        /// Another instance already runs — this launch must stand down.
        case anotherInstanceRunning
    }

    /// - Parameter otherInstanceCount: running processes that share this app's bundle
    ///   identifier, with the current process excluded. A non-positive value fails open.
    public static func decide(otherInstanceCount: Int) -> Decision {
        otherInstanceCount > 0 ? .anotherInstanceRunning : .proceed
    }
}
