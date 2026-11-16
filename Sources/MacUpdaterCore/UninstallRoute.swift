import Foundation
import WegaHelperKit

public enum UninstallHelperAvailability: Equatable, Sendable { case notSupported, off, enabled }

public struct UninstallBundleFacts: Equatable, Sendable {
    public var ownerUID: UInt32
    public var currentUserUID: UInt32
    public var isWritableByUser: Bool
    public var isTopLevelInApplications: Bool
    public var hasBundleIdentifier: Bool
    public var isAdministrator: Bool
    public var helper: UninstallHelperAvailability

    public init(
        ownerUID: UInt32, currentUserUID: UInt32, isWritableByUser: Bool,
        isTopLevelInApplications: Bool, hasBundleIdentifier: Bool,
        isAdministrator: Bool, helper: UninstallHelperAvailability
    ) {
        self.ownerUID = ownerUID
        self.currentUserUID = currentUserUID
        self.isWritableByUser = isWritableByUser
        self.isTopLevelInApplications = isTopLevelInApplications
        self.hasBundleIdentifier = hasBundleIdentifier
        self.isAdministrator = isAdministrator
        self.helper = helper
    }
}

public enum UninstallRouteDecision: Equatable, Sendable { case userTrash, helper, blocked(UninstallBlock) }

public enum UninstallRoute {
    /// A bundle the user can write to, or owns, is tried in the user's Trash first; only a
    /// refusal there reaches `afterPermissionDenied`.
    public static func preflight(_ facts: UninstallBundleFacts) -> UninstallRouteDecision {
        if facts.isWritableByUser || facts.ownerUID == facts.currentUserUID {
            return .userTrash
        }
        return afterPermissionDenied(facts)
    }

    /// The helper is offered only for a root-owned, top-level `/Applications` bundle that has a
    /// bundle identifier; every other refusal is reported with its own reason.
    public static func afterPermissionDenied(_ facts: UninstallBundleFacts) -> UninstallRouteDecision {
        if facts.ownerUID == facts.currentUserUID { return .blocked(.needsAppManagement) }
        if facts.ownerUID != 0 || !facts.isTopLevelInApplications || !facts.hasBundleIdentifier {
            return .blocked(.needsAdministratorRights)
        }
        if facts.helper == .notSupported { return .blocked(.needsAdministratorRights) }
        if !facts.isAdministrator { return .blocked(.needsAdministratorAccount) }
        if facts.helper == .off { return .blocked(.needsHelper) }
        return .helper
    }

    public static func isPermissionDenied(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileWriteNoPermission.rawValue {
                return true
            }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}

extension UninstallBundleFacts {
    /// Reads the facts from the live filesystem. The owner comes from `lstat`, which does not
    /// follow a symlink. A bundle that vanished (`ENOENT`) routes to the user's Trash so the
    /// real "no such file" error surfaces as a failure. Any other inspection failure reads as
    /// not writable and owned by nobody, so the route fails toward a blocked result and never
    /// toward an attempt as root.
    public static func live(path: URL, hasBundleIdentifier: Bool) -> UninstallBundleFacts {
        let currentUser = getuid()
        var status = stat()
        guard lstat(path.path, &status) == 0 else {
            let vanished = errno == ENOENT
            return UninstallBundleFacts(
                ownerUID: vanished ? currentUser : UInt32.max,
                currentUserUID: currentUser,
                isWritableByUser: vanished,
                isTopLevelInApplications: WegaHelper.isTopLevelApplicationBundle(path: path.path),
                hasBundleIdentifier: hasBundleIdentifier,
                isAdministrator: AdministratorGroup.contains(uid: currentUser),
                helper: .notSupported
            )
        }
        let owner: UInt32 = status.st_uid
        let writable = access(path.path, W_OK) == 0
            && access(path.deletingLastPathComponent().path, W_OK) == 0
        return UninstallBundleFacts(
            ownerUID: owner,
            currentUserUID: currentUser,
            isWritableByUser: writable,
            isTopLevelInApplications: WegaHelper.isTopLevelApplicationBundle(path: path.path),
            hasBundleIdentifier: hasBundleIdentifier,
            isAdministrator: AdministratorGroup.contains(uid: currentUser),
            helper: .notSupported
        )
    }
}
