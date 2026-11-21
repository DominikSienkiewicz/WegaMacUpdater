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

    /// Adds the exact directive `auth       sufficient     pam_tid.so` to `/etc/pam.d/sudo_local` as root, or writes
    /// Apple's template with it when there is no `sudo_local`; only for the administrator at the console, and only
    /// when `/etc/pam.d`, `sudo_local` and the template are root's alone. Takes no arguments: the paths are fixed in
    /// the helper. `code` 1: written and read back. 0: `sudo_local` already holds an active `pam_tid` line; nothing
    /// was written. −1…−7 and −10: a `TouchIDSudoEnableRefusal`; nothing was written. −20: the write failed and the
    /// previous state is back. −21: the write failed and could not be undone, or the file read back after it is not
    /// the one planned; `detail` is the backup of the previous file, or nil when none is left. Protocol 8; the reply of `enableTouchIDForSudo(withReply:)` (v6/v7, `(Bool, String?)`) had another
    /// shape, so this is a new selector and the old one is gone.
    func enableTouchIDForSudoChecked(withReply reply: @escaping @Sendable (Int, String?) -> Void)

    /// Removes the exact directive `auth       sufficient     pam_tid.so` (Apple's template line without its `#`)
    /// from `/etc/pam.d/sudo_local`, and only when nothing but blank and comment lines would remain.
    /// Takes no arguments: the paths are fixed in the helper. `code` > 0: that many lines were removed and the
    /// result was verified. 0: no file, or no exact directive; nothing was written. −1…−9 and −11: a
    /// `TouchIDSudoDisableRefusal`; nothing was written. −10: `sudo_local` changed while the helper worked; this can
    /// follow a swap, and the previous file may then be left under the swap name. −20: a step failed and
    /// `sudo_local` is the original file again. −21: swapping back failed or could not be decided; `detail` is the
    /// path that holds the previous file.
    func disableTouchIDForSudo(withReply reply: @escaping @Sendable (Int, String?) -> Void)

    /// Reserves a durable operation before starting the verified installer on a worker queue.
    /// Replies carry JSON-encoded `PackageInstallationStatus`; a transport error is not a result.
    func beginPackageInstallation(atPath path: String, operationID: String, expectedVersion: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)

    /// A missing ID is durably marked not-started, preventing a delayed start request.
    func packageInstallationStatus(operationID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)

    /// FEAT-05 rollback for protected locations: atomically replaces the `.app`
    /// at `targetPath` with the clone at `snapshotPath`, as root. The helper
    /// validates both are `.app` bundles, the target sits under `/Applications`,
    /// and the snapshot passes Gatekeeper — so this is NOT a generic "overwrite
    /// any path as root" primitive.
    func replaceBundle(atPath targetPath: String, withSnapshotAtPath snapshotPath: String, withReply reply: @escaping @Sendable (Bool, String?) -> Void)

    /// Moves a root-owned application out of `/Applications` into a fresh staging slot under
    /// `UninstallStaging.root` and hands it to the calling administrator, who then puts it in
    /// the Trash as themselves. Root never writes into a home directory.
    ///
    /// The helper refuses anything but a plainly spelled top-level application that belongs to
    /// root, carries `expectedBundleID` and is not Wega; the caller must be the administrator at
    /// the console. The reply is `(stagedPath, error)`: a path with no error is a complete
    /// hand-over; a path *with* a note means the bundle left `/Applications` but some items
    /// stayed root-owned; no path means nothing was moved, or that a swapped entry was left in
    /// a root-only slot.
    func stageApplicationBundleForTrash(atPath path: String, expectedBundleID: String, withReply reply: @escaping @Sendable (String?, String?) -> Void)
}

/// The privileged verbs of `WegaPrivilegedOps`, each checked against its own minimum helper
/// version before the app sends it (`WegaHelper.minimumHelperVersion(for:)`).
public enum WegaHelperVerb: String, CaseIterable, Sendable {
    case enableTouchIDForSudo, beginPackageInstallation, packageInstallationStatus, replaceBundle,
         stageApplicationBundleForTrash, disableTouchIDForSudo
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
    /// Helper protocol version. Bumped with every new verb and every change to a verb's
    /// arguments, reply or semantics; see `minimumHelperVersion(for:)`.
    public static let version = "9"

    /// The oldest helper protocol version whose behaviour for `verb` this app relies on.
    ///
    /// Rule: adding a verb bumps `version` and sets the new verb's minimum to it. Changing a verb's
    /// arguments, reply or semantics bumps `version` and raises THAT verb's minimum to it.
    /// A changed reply shape gets a new selector, so a helper that predates it fails instead of
    /// decoding the reply as another shape. A change that makes older helpers unsafe for every verb
    /// raises every minimum.
    ///
    /// Protocol 9 (Z14) is such a change: a helper from 9 on serves no one when its own bundle fails
    /// `HelperBundleGate`, and an older one cannot tell, so every verb that acts needs 9. The status
    /// query stays at 6, so an older helper can still report an installation it ran.
    public static func minimumHelperVersion(for verb: WegaHelperVerb) -> Int {
        switch verb {
        case .packageInstallationStatus:
            return 6
        case .beginPackageInstallation, .replaceBundle, .stageApplicationBundleForTrash,
             .enableTouchIDForSudo, .disableTouchIDForSudo:
            return 9
        }
    }

    /// Apple Developer Team ID — pinned by XPC (both directions) and self-update
    /// verification. Must match the Developer ID certificate the app is signed with.
    public static let teamIdentifier = "6B8FYSZFJK"

    /// Requirement the **app** must satisfy — enforced by the helper on every
    /// incoming XPC connection. Pins Apple chain + app identifier + a Developer ID
    /// signature + Team ID. `scripts/verify-bundle.sh` holds this exact text and checks
    /// the signed release against it.
    public static func clientRequirement() -> String {
        "anchor apple generic and identifier \"\(appBundleID)\" " + developerIDTeamClauses
    }

    /// Requirement the **helper** must satisfy — enforced by the app before it
    /// trusts the daemon it connected to. Same shape as `clientRequirement()`; both
    /// binaries are signed with the same Developer ID Application identity.
    public static func helperRequirement() -> String {
        "anchor apple generic and identifier \"\(helperSigningID)\" " + developerIDTeamClauses
    }

    /// R2-5: the Developer ID intermediate CA marker (…6.2.6, G1 and G2) and the Developer ID
    /// Application leaf marker (…6.1.13), then the Team ID. The same team's Apple Development
    /// or Apple Distribution signature has the OU and an Apple anchor but not these markers.
    private static var developerIDTeamClauses: String {
        "and certificate 1[field.1.2.840.113635.100.6.2.6] "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] "
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

extension WegaHelper {
    /// Whether `path` names an application directly in `/Applications` or in one plain folder
    /// beneath it (`/Applications/Utilities/Foo.app`), and not a bundle nested inside another.
    ///
    /// Decided on the standardized path components, as `bundleReplacementRejection` does:
    /// `/Applications/../tmp/a.app` resolves outside and is refused, while
    /// `/Applications/Sub/../Foo.app` resolves to `/Applications/Foo.app` and is accepted.
    public static func isTopLevelApplicationBundle(path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count == 3 || components.count == 4,
              components[0] == "/",
              components[1] == "Applications",
              let name = components.last,
              name.hasSuffix(".app") else {
            return false
        }
        return components.count == 3 || !components[2].hasSuffix(".app")
    }
}

/// Why the root helper refuses to move an application out of `/Applications` into a staging
/// slot owned by the caller, or why it cannot trust the staging root it would move it into.
public enum BundleStagingRejection: Equatable, Sendable {
    /// The path is not a plainly spelled `/Applications/<name>.app` or
    /// `/Applications/<folder>/<name>.app`.
    case notTopLevelApplication
    /// The target is a symlink, or `realpath` names a different entry than the path asked for.
    case symlinkedTarget
    /// The target resolves into the system volume.
    case systemLocation
    /// The bundle does not belong to root. A user-owned bundle never needs the helper: when the
    /// user cannot move it, App Management blocks it, and the helper must not override that.
    case notOwnedByRoot
    /// The bundle carries no identifier, or not the one the user saw in the scan.
    case identityMismatch
    /// The bundle is Wega itself, which carries this helper.
    case wegaItself
    /// Nobody is logged in at the console.
    case noConsoleUser
    /// The caller is not the user at the console (fast user switching).
    case callerNotConsoleUser
    /// The caller is not a member of the `admin` group.
    case callerNotAdministrator
    /// The entry changed between validation and the move.
    case targetSwapped
    /// The staging root is not root's alone.
    case stagingRootUnsafe
}

/// What the daemon learned, as root and right before the move, about the caller and the bundle
/// it asked to stage. Passed in rather than read here so the decision stays testable.
public struct BundleStagingFacts: Equatable, Sendable {
    /// The path the client asked for, exactly as it was sent.
    public var targetPath: String
    /// `realpath` of the target, with every symlink resolved.
    public var targetResolvedPath: String
    /// Whether the target itself is a symbolic link (`lstat`, not `stat`).
    public var targetIsSymlink: Bool
    /// Owner of the bundle directory (`lstat`).
    public var targetOwnerUID: UInt32
    /// `CFBundleIdentifier` from the bundle's `Info.plist`, or `nil` when unreadable.
    public var targetBundleID: String?
    /// The identifier the client says the user saw in the scan.
    public var expectedBundleID: String
    /// `effectiveUserIdentifier` of the XPC connection.
    public var callerUID: UInt32
    /// Owner of the current console session, or `nil` when nobody is logged in.
    public var consoleUserUID: UInt32?
    /// Whether the caller is a member of the `admin` group.
    public var callerIsAdministrator: Bool

    public init(
        targetPath: String,
        targetResolvedPath: String,
        targetIsSymlink: Bool,
        targetOwnerUID: UInt32,
        targetBundleID: String?,
        expectedBundleID: String,
        callerUID: UInt32,
        consoleUserUID: UInt32?,
        callerIsAdministrator: Bool
    ) {
        self.targetPath = targetPath
        self.targetResolvedPath = targetResolvedPath
        self.targetIsSymlink = targetIsSymlink
        self.targetOwnerUID = targetOwnerUID
        self.targetBundleID = targetBundleID
        self.expectedBundleID = expectedBundleID
        self.callerUID = callerUID
        self.consoleUserUID = consoleUserUID
        self.callerIsAdministrator = callerIsAdministrator
    }
}

extension WegaHelper {
    /// The lexical gate for staging an application for the Trash.
    ///
    /// Stricter than `isTopLevelApplicationBundle`, which the app's preflight uses and which
    /// accepts a `..` that standardizes back into `/Applications`: the root helper takes only a
    /// plainly spelled path, so the string it approves is the entry the kernel resolves. The
    /// folder in `/Applications/<folder>/<name>.app` must not be a bundle in any letter case,
    /// because Launch Services treats `X.APP` as an application just as it does `X.app`.
    public static func bundleStagingRejection(targetPath: String) -> BundleStagingRejection? {
        guard namesEveryComponentPlainly(targetPath),
              isTopLevelApplicationBundle(path: targetPath),
              !hasBundleFolder(targetPath) else {
            return .notTopLevelApplication
        }
        return nil
    }

    /// The facts gate for staging an application for the Trash.
    ///
    /// Checked in a fixed order: the caller first, so somebody who may not ask learns nothing
    /// about the target; then where the target really is; then its owner; then its identity.
    public static func bundleStagingRejection(facts: BundleStagingFacts) -> BundleStagingRejection? {
        if let rejection = callerRejection(facts) { return rejection }
        if let rejection = locationRejection(facts) { return rejection }
        if facts.targetOwnerUID != 0 { return .notOwnedByRoot }
        return identityRejection(facts)
    }

    /// The entry validated must be the entry moved: a device/inode pair that changed in between
    /// is a swap, and refused.
    public static func bundleStagingRejection(
        validated: PackageStaging.ArtifactIdentity,
        current: PackageStaging.ArtifactIdentity
    ) -> BundleStagingRejection? {
        validated == current ? nil : .targetSwapped
    }

    private static func callerRejection(_ facts: BundleStagingFacts) -> BundleStagingRejection? {
        guard let consoleUserUID = facts.consoleUserUID else { return .noConsoleUser }
        guard facts.callerUID == consoleUserUID else { return .callerNotConsoleUser }
        guard facts.callerIsAdministrator else { return .callerNotAdministrator }
        return nil
    }

    /// The resolved path must be the path asked for, and must clear the lexical gate on its own,
    /// so this gate holds even if the daemon passed it a path the lexical gate never saw.
    private static func locationRejection(_ facts: BundleStagingFacts) -> BundleStagingRejection? {
        if isInSystemVolume(facts.targetResolvedPath) { return .systemLocation }
        if facts.targetIsSymlink || facts.targetResolvedPath != facts.targetPath { return .symlinkedTarget }
        return bundleStagingRejection(targetPath: facts.targetResolvedPath)
    }

    /// A missing or empty identifier is a rejection, not a pass. Wega is excluded ignoring case,
    /// as Launch Services compares bundle identifiers.
    private static func identityRejection(_ facts: BundleStagingFacts) -> BundleStagingRejection? {
        guard let bundleID = facts.targetBundleID, !bundleID.isEmpty, bundleID == facts.expectedBundleID else {
            return .identityMismatch
        }
        return bundleID.caseInsensitiveCompare(appBundleID) == .orderedSame ? .wegaItself : nil
    }

    private static func isInSystemVolume(_ path: String) -> Bool {
        let components = path.utf8.split(separator: pathSeparator)
        return components.first?.elementsEqual("System".utf8) ?? false
    }

    /// Absolute, with every component a real name: no `.`, no `..`, no empty component (`//` or
    /// a trailing `/`, after which `lstat` follows a final symlink) and no NUL. Read as UTF-8
    /// bytes, the way the kernel reads it — a split on Swift `Character`s misses a `/` that a
    /// following combining mark fuses into one grapheme.
    static func namesEveryComponentPlainly(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard bytes.first == pathSeparator, !bytes.contains(0) else { return false }
        return bytes.dropFirst()
            .split(separator: pathSeparator, omittingEmptySubsequences: false)
            .allSatisfy { component in
                !component.isEmpty
                    && !component.elementsEqual(".".utf8)
                    && !component.elementsEqual("..".utf8)
            }
    }

    /// Whether the folder between `/Applications` and the application ends in `.app`, ignoring
    /// case. Only called on a path whose components are plain, so the byte split is the path.
    private static func hasBundleFolder(_ path: String) -> Bool {
        let components = path.utf8.split(separator: pathSeparator)
        guard components.count == 3 else { return false }
        return String(decoding: components[1], as: UTF8.self).lowercased().hasSuffix(".app")
    }

    private static let pathSeparator = UInt8(ascii: "/")
}
