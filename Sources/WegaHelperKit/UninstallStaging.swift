import Foundation

/// Where the root helper parks a root-owned application on its way to the caller's Trash.
///
/// Each move goes into a fresh `<uuid>/` slot below this root, owned by the caller. The root
/// lives on the Data volume next to `PackageStaging`, so moving a bundle in from
/// `/Applications` is one atomic `rename`, and root never writes into a home directory.
public enum UninstallStaging {
    public static let root = SystemPaths.systemApplicationSupportDirectory
        .appendingPathComponent(WegaHelper.appBundleID, isDirectory: true)
        .appendingPathComponent("UninstallStaging", isDirectory: true)

    /// The root must be owned by root with mode exactly `0711`, checked on every call as
    /// `PackageStaging` does. `permissions` is `st_mode & 0o7777`.
    ///
    /// Exactly, not "at most": `0700` would lock callers out of their own slots, anything wider
    /// lets others list or write it, and a setuid, setgid or sticky bit means the directory is
    /// not the one the helper made.
    public static func rootRejection(ownerUID: UInt32, permissions: UInt16) -> BundleStagingRejection? {
        ownerUID == 0 && permissions == 0o711 ? nil : .stagingRootUnsafe
    }
}
