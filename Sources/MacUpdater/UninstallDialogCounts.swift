import MacUpdaterCore

/// The counts the confirmation sheet states. A non-brew target whose route is blocked is not
/// counted as going to the Trash: it will be reported instead of removed.
struct UninstallDialogCounts: Equatable {
    let brew: Int
    let trash: Int
    let blocked: Int

    init(targets: [ApplicationInfo], routes: [String: UninstallRouteDecision]) {
        let removable = targets.filter {
            if case .blocked = routes[$0.id] { return false }
            return true
        }
        brew = removable.filter(\.isManagedByBrew).count
        trash = removable.count - brew
        blocked = targets.count - removable.count
    }

    var promisesTrash: Bool { trash > 0 }

    /// Every target is blocked: confirming removes nothing and quits nothing.
    var removesNothing: Bool { brew == 0 && trash == 0 }
}
