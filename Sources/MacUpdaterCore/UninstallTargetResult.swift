import Foundation

/// Why a removal could not proceed without Wega's helper or a permission the user has to grant.
public enum UninstallBlock: Equatable, Sendable {
    case needsHelper
    case needsAdministratorAccount
    case needsAdministratorRights
    case needsAppManagement
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

    public var isRemoved: Bool {
        switch self {
        case .removedByHomebrew, .movedToTrash, .movedToTrashByHelper:
            return true
        case .skippedStillRunning, .skippedAmbiguousProcess, .blocked, .leftInStaging, .failed:
            return false
        }
    }
}
