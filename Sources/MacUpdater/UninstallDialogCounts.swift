import MacUpdaterCore

/// The counts the confirmation sheet states. A non-brew target whose route is blocked is not
/// counted as going to the Trash: it will be reported instead of removed.
struct UninstallDialogCounts: Equatable {
    let brew: Int
    let trash: Int
    let blocked: Int

    init(targets: [ApplicationInfo], routes: [String: UninstallRouteDecision]) {
        let nonBrew = targets.filter { !$0.isManagedByBrew }
        let blockedCount = nonBrew.filter {
            if case .blocked = routes[$0.id] { return true }
            return false
        }.count
        brew = targets.count - nonBrew.count
        blocked = blockedCount
        trash = nonBrew.count - blockedCount
    }

    var promisesTrash: Bool { trash > 0 }
}
