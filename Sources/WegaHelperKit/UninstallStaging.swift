import Foundation

/// Where the root helper parks a root-owned application on its way to the caller's Trash.
///
/// Each move goes into a fresh `<uuid>/` slot below this root, in this order:
/// 1. the slot is created owned by root, mode `0700`, so the caller cannot enter it yet;
/// 2. the bundle is `rename`d in, refusing a symlink in any component of either path;
/// 3. the entry now in the slot is checked to be the device/inode that was validated;
/// 4. the moved tree is handed to the caller by a physical walk that stays on the bundle's
///    volume and leaves any non-directory with a second hard link root-owned;
/// 5. only then is the slot itself given to the caller, still `0700`.
///
/// While steps 2 to 4 run the caller cannot reach the tree through the slot, so it cannot swap
/// in a hard link to a root-owned file for root to give away. The root lives on the Data volume
/// next to `PackageStaging`, so moving a bundle in from `/Applications` is one atomic `rename`,
/// and root never writes into a home directory.
public enum UninstallStaging {
    public static let root = SystemPaths.systemApplicationSupportDirectory
        .appendingPathComponent(WegaHelper.appBundleID, isDirectory: true)
        .appendingPathComponent("UninstallStaging", isDirectory: true)

    /// The root must be a directory owned by root with mode exactly `0711`, checked on every
    /// call as `PackageStaging` does. The facts come from `lstat`; `permissions` is
    /// `st_mode & 0o7777`.
    ///
    /// Exactly, not "at most": `0700` would lock callers out of their own slots, anything wider
    /// lets others list or write it, and a setuid, setgid or sticky bit means the directory is
    /// not the one the helper made. A symlink is refused whatever its own mode, which `lchmod`
    /// can set to `0711`.
    public static func rootRejection(ownerUID: UInt32, permissions: UInt16, isDirectory: Bool) -> BundleStagingRejection? {
        rootRejection(ownerUID: ownerUID, requiredOwnerUID: 0, permissions: permissions, isDirectory: isDirectory)
    }

    /// The same rule for a root that must belong to `requiredOwnerUID`: root in the helper, the
    /// test's own account when `prepareRoot` runs unprivileged.
    static func rootRejection(
        ownerUID: UInt32, requiredOwnerUID: UInt32, permissions: UInt16, isDirectory: Bool
    ) -> BundleStagingRejection? {
        isDirectory && ownerUID == requiredOwnerUID && permissions == 0o711 ? nil : .stagingRootUnsafe
    }
}
