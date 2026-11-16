import Foundation

/// Why a removal could not proceed without Wega's helper or a permission the user has to grant.
public enum UninstallBlock: Equatable, Sendable {
    case needsHelper
    case needsAdministratorAccount
    case needsAdministratorRights
    case needsAppManagement
}

/// Why an app is never offered for removal.
public enum UninstallProtection: Equatable, Sendable {
    case wegaItself
    case systemApplication
    case symlink(destination: String)
}

/// What happened to one uninstall target. Only the `removed*` cases mean the app is gone, so
/// only they release the app's `~/Library` leftovers for the Trash.
public enum UninstallTargetResult: Equatable, Sendable {
    case removedByHomebrew
    case movedToTrash
    case movedToTrashByHelper
    case skippedStillRunning
    case skippedAmbiguousProcess
    case blocked(UninstallBlock)
    case leftInStaging(URL)
    case failed(String)
    case protected(UninstallProtection)

    public var isRemoved: Bool {
        switch self {
        case .removedByHomebrew, .movedToTrash, .movedToTrashByHelper:
            return true
        case .skippedStillRunning, .skippedAmbiguousProcess, .blocked, .leftInStaging, .failed, .protected:
            return false
        }
    }
}
