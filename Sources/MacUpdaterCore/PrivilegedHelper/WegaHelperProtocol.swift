import Foundation

/// Shared contract between the GUI app (client) and the privileged daemon
/// (server) — finding **FEAT-01 / Prop#1**.
///
/// Security model:
/// - The helper runs as root, registered via `SMAppService.daemon(plistName:)`.
/// - The interface is a **finite whitelist of verbs** (NO generic `runCommand`),
///   so a compromised or spoofed client cannot turn the helper into a root shell.
/// - Both ends pin each other's code signature (`setCodeSigningRequirement`,
///   macOS 13+), which is enforced by the kernel using the peer's audit token —
///   not a forgeable PID.
///
/// ⚠️ Reply handlers are the XPC idiom (NSXPCConnection does not bridge
/// `async` across the wire). They are marked `@Sendable` for Swift 6 strict
/// concurrency.
@objc public protocol WegaPrivilegedOps {
    /// Handshake / version probe — lets the client detect a stale helper after
    /// an app update and re-register if needed.
    func helperVersion(withReply reply: @escaping @Sendable (String) -> Void)

    /// Writes `auth sufficient pam_tid.so` into `/etc/pam.d/sudo_local` as root.
    /// Replaces the `osascript ... with administrator privileges` path — no
    /// password dialog, because the helper is already root.
    func enableTouchIDForSudo(withReply reply: @escaping @Sendable (Bool, String?) -> Void)

    /// Installs a `.pkg` at `path` as root via `/usr/sbin/installer`, but ONLY
    /// after the helper itself re-verifies the package signature/notarization +
    /// Team ID (defense in depth — never trust the client's path blindly).
    func installVerifiedPackage(atPath path: String, withReply reply: @escaping @Sendable (Bool, String?) -> Void)

    /// FEAT-05 rollback for protected locations: atomically replaces the `.app`
    /// at `targetPath` with the clone at `snapshotPath`, as root. The helper
    /// validates both are `.app` bundles, the target sits under `/Applications`,
    /// and the snapshot passes Gatekeeper — so this is NOT a generic "overwrite
    /// any path as root" primitive.
    func replaceBundle(atPath targetPath: String, withSnapshotAtPath snapshotPath: String, withReply reply: @escaping @Sendable (Bool, String?) -> Void)
}

/// Identity & code-requirement constants shared by client and helper.
///
/// 🔑 `teamIdentifier` is the **single source of truth** for the Team ID across
/// the whole app (self-update pin in `CodeSignatureVerifier`, XPC peer pinning,
/// build signing). Set it once here.
public enum WegaHelper {
    /// launchd label and Mach service name of the daemon.
    public static let machServiceName = "com.wega.WegaMacUpdater.helper"
    /// File name of the bundled launchd plist (in `Contents/Library/LaunchDaemons/`).
    public static let plistName = "com.wega.WegaMacUpdater.helper.plist"
    /// Code-signing identifier the helper binary is signed with (`codesign -i …`).
    public static let helperSigningID = "com.wega.WegaMacUpdater.helper"
    /// Main app bundle identifier.
    public static let appBundleID = AppMetadata.bundleIdentifier
    /// Helper protocol version (bump on breaking interface changes).
    public static let version = "2"

    /// Apple Developer Team ID — pinned by XPC (both directions) and self-update
    /// verification. Must match the Developer ID certificate the app is signed with.
    public static let teamIdentifier = "6B8FYSZFJK"

    /// Requirement the **app** must satisfy — enforced by the helper on every
    /// incoming XPC connection. Pins Apple chain + app identifier + Team ID.
    public static func clientRequirement() -> String {
        "anchor apple generic and identifier \"\(appBundleID)\" "
        + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// Requirement the **helper** must satisfy — enforced by the app before it
    /// trusts the daemon it connected to.
    public static func helperRequirement() -> String {
        "anchor apple generic and identifier \"\(helperSigningID)\" "
        + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// True once a real Team ID has been configured (guards fail-closed paths in
    /// debug/ad-hoc builds where signing isn't set up yet).
    public static var isTeamIDConfigured: Bool { teamIdentifier != "REPLACE_TEAMID" }
}
