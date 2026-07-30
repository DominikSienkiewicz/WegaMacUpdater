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
    /// Signing identifiers of the compiled, bundle-sealed authorization components.
    public static let askpassSigningID = "com.wega.WegaMacUpdater.askpass"
    public static let sudoShimSigningID = "com.wega.WegaMacUpdater.sudo-shim"
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

    /// Why the root helper refuses a `replaceBundle` request outright, or `nil` when the
    /// paths clear the structural gate and the daemon proceeds to its filesystem +
    /// Gatekeeper checks.
    public enum BundleReplacementRejection: Equatable, Sendable {
        /// Target or snapshot is not a `.app` bundle.
        case notBundle
        /// Target escapes the `/Applications/` install root.
        case outsideApplications
        /// The target is a symlink, or is reached through one — the path the gate approved
        /// is not the path the filesystem would write to (SEC-03).
        case symlinkedTarget
        /// Snapshot and target are not the same application: bundle identifier or signing
        /// Team ID differ, or either is missing (SEC-03).
        case identityMismatch
        /// The target belongs to neither root nor the console user — replacing another
        /// account's application is not something this helper does (SEC-03).
        case foreignOwner
        /// The target changed between validation and the replacement itself (SEC-03).
        case targetSwapped
    }

    /// The identifiers that bind a bundle snapshot to the installed application it may
    /// replace. Either value may be absent when the bundle cannot be inspected; the gate
    /// rejects such incomplete identities.
    public struct BundleIdentity: Equatable, Sendable {
        public var bundleID: String?
        public var teamID: String?

        public init(bundleID: String?, teamID: String?) {
            self.bundleID = bundleID
            self.teamID = teamID
        }
    }

    /// What the daemon learned about the two bundles from the filesystem, gathered as root
    /// immediately before the replacement.
    ///
    /// Passed in rather than read here so the decision stays testable: `WegaPrivilegedHelper`
    /// runs only as root and no test target can reach it, which is how the `..` traversal
    /// survived unnoticed in the first place.
    public struct BundleReplacementFacts: Equatable, Sendable {
        /// `realpath` of the target, with every symlink resolved.
        public var targetResolvedPath: String
        /// Whether the target itself is a symbolic link (`lstat`, not `stat`).
        public var targetIsSymlink: Bool
        public var targetBundleID: String?
        public var targetTeamID: String?
        public var snapshotBundleID: String?
        public var snapshotTeamID: String?
        /// Owner of the target bundle.
        public var targetOwnerUID: UInt32
        /// Owner of the current console session, or `nil` when nobody is logged in.
        public var consoleUserUID: UInt32?
    }

    /// SEC-03: the checks that need the filesystem, kept as a pure function over facts the
    /// daemon gathers.
    ///
    /// Two things the lexical gate cannot see. First, a symlink: `/Applications/Foo.app` may
    /// point anywhere, so approving the literal path says nothing about what gets written —
    /// the resolved path has to clear the same gate. Second, identity: without it the helper
    /// happily restores *any* signed bundle over *any* target, which makes it a generic
    /// "replace this as root" primitive. Requiring a matching bundle identifier and Team ID
    /// means a snapshot can only ever overwrite the application it was taken from.
    ///
    /// A missing identifier or Team ID is a rejection, not a pass: unsigned or unreadable
    /// input is exactly the case an attacker controls.
    public static func bundleReplacementRejection(
        facts: BundleReplacementFacts
    ) -> BundleReplacementRejection? {
        if facts.targetIsSymlink { return .symlinkedTarget }

        // The resolved path must clear the structural gate too — a symlinked *parent*
        // (`/Applications/Legit.app` under a swapped directory) leaves the target itself an
        // ordinary directory while still redirecting the write.
        if bundleReplacementRejection(
            targetPath: facts.targetResolvedPath,
            snapshotPath: facts.targetResolvedPath
        ) != nil {
            return .symlinkedTarget
        }

        // Ownership, measured rather than assumed: on a real system most of `/Applications`
        // belongs to the logged-in user, not to root — 29 of 42 bundles on the machine this
        // was written against. Demanding root ownership would refuse rollback for two thirds
        // of the installed applications, a regression larger than the hole it closes. What is
        // worth refusing is a bundle owned by some *other* account: replacing another user's
        // application is not something this helper has any business doing.
        if facts.targetOwnerUID != 0, facts.targetOwnerUID != facts.consoleUserUID {
            return .foreignOwner
        }

        guard let targetBundleID = facts.targetBundleID,
              let snapshotBundleID = facts.snapshotBundleID,
              let targetTeamID = facts.targetTeamID,
              let snapshotTeamID = facts.snapshotTeamID,
              targetBundleID == snapshotBundleID,
              targetTeamID == snapshotTeamID else {
            return .identityMismatch
        }
        return nil
    }

    /// The structural path gate for `WegaPrivilegedOps.replaceBundle`, lifted out of the
    /// (untestable, root-only) daemon so the decision it makes as root can be pinned by a
    /// unit test. Both paths must be `.app` bundles and the target must live under
    /// `/Applications/`; the filesystem and Gatekeeper checks that follow stay in the daemon.
    ///
    /// SEC-03: the gate canonicalises before it compares, and compares *path components*
    /// rather than string prefixes.
    ///
    /// It used to be a plain `hasPrefix("/Applications/")`, which admitted
    /// `/Applications/../tmp/evil.app` — a path that resolves to `/tmp/evil.app` and turned the
    /// root helper into a primitive for replacing any bundle on the system. Two separate
    /// mistakes had to be fixed: `..` was never resolved, and a prefix test also accepts
    /// `/ApplicationsEvil/Foo.app`, which shares the characters but not the directory.
    ///
    /// `standardizedFileURL` resolves `.` and `..` lexically, without touching the filesystem,
    /// so this stays a pure decision a unit test can pin — the daemon it protects is
    /// root-only and unreachable from any test target. Symlinks, ownership and the
    /// device/inode identity of the target need the filesystem and are checked separately in
    /// the daemon; this gate is the part that can be proven.
    public static func bundleReplacementRejection(
        targetPath: String,
        snapshotPath: String
    ) -> BundleReplacementRejection? {
        guard targetPath.hasSuffix(".app"), snapshotPath.hasSuffix(".app") else {
            return .notBundle
        }
        // Absolute paths only. A relative path would be resolved against the daemon's working
        // directory, which is not part of the trust boundary and must never decide the answer.
        guard targetPath.hasPrefix("/"), snapshotPath.hasPrefix("/") else {
            return .outsideApplications
        }
        let standardized = URL(fileURLWithPath: targetPath).standardizedFileURL
        let components = standardized.pathComponents
        guard components.count >= 3,
              components[0] == "/",
              components[1] == "Applications",
              standardized.pathExtension == "app" else {
            return .outsideApplications
        }
        return nil
    }

    /// SEC-03: the target validated must be the target replaced.
    ///
    /// Everything above decides on a path; between that decision and `replaceItemAt` the entry
    /// could be exchanged for another. Comparing the filesystem identity across that span turns
    /// the substitution into a refusal instead of a root-privileged overwrite of the wrong
    /// bundle. `PackageStaging.ArtifactIdentity` is reused deliberately — a device/inode pair
    /// means the same thing here as it does for a staged package.
    public static func bundleReplacementRejection(
        validated: PackageStaging.ArtifactIdentity,
        replacing: PackageStaging.ArtifactIdentity
    ) -> BundleReplacementRejection? {
        validated == replacing ? nil : .targetSwapped
    }
}

extension WegaHelper.BundleReplacementFacts {
    /// Public construction groups the identifiers by bundle. The internal memberwise
    /// initializer remains available to `@testable` clients that use the original flat shape.
    public init(
        targetResolvedPath: String,
        targetIsSymlink: Bool,
        targetIdentity: WegaHelper.BundleIdentity,
        snapshotIdentity: WegaHelper.BundleIdentity,
        targetOwnerUID: UInt32,
        consoleUserUID: UInt32?
    ) {
        self.init(
            targetResolvedPath: targetResolvedPath,
            targetIsSymlink: targetIsSymlink,
            targetBundleID: targetIdentity.bundleID,
            targetTeamID: targetIdentity.teamID,
            snapshotBundleID: snapshotIdentity.bundleID,
            snapshotTeamID: snapshotIdentity.teamID,
            targetOwnerUID: targetOwnerUID,
            consoleUserUID: consoleUserUID
        )
    }
}
