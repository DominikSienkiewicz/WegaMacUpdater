import Foundation
import MacUpdaterCore

enum UninstallForceQuitChoice { case forceQuit, skip, cancel }

/// Decides which targets may go to removal once the quit phase, and the user's answer to
/// the force-quit sheet, are known. Only a target confirmed stopped is ever removable.
enum UninstallQuitFlow {
    typealias Plan = (remove: [ApplicationInfo], skipped: [String: UninstallTargetResult])

    /// Splits the confirmed targets into those Wega will attempt and those whose preflight
    /// route is already blocked. A blocked target is reported with that block as it stands,
    /// never re-routed later, so a change in its facts can never trash a running app.
    static func partition(
        targets: [ApplicationInfo],
        routes: [String: UninstallRouteDecision]
    ) -> (attempt: [ApplicationInfo], blocked: [String: UninstallTargetResult]) {
        var attempt: [ApplicationInfo] = []
        var blocked: [String: UninstallTargetResult] = [:]
        for app in targets {
            if case .blocked(let block) = routes[app.id] {
                blocked[app.id] = .blocked(block)
            } else {
                attempt.append(app)
            }
        }
        return (attempt, blocked)
    }

    /// - Returns: the targets to remove and the pre-filled skip results, or `nil` when the
    ///   user cancelled (or left stubborn apps unanswered), in which case nothing is removed.
    static func plan(
        targets: [ApplicationInfo],
        quit: UninstallQuitResult,
        choice: UninstallForceQuitChoice?,
        forced: UninstallQuitResult?
    ) -> Plan? {
        if choice == .cancel { return nil }
        if choice == nil, !quit.stillRunning.isEmpty { return nil }

        var stopped = quit.stopped
        var ambiguous = quit.ambiguous
        if choice == .forceQuit, let forced {
            stopped.formUnion(forced.stopped)
            ambiguous.formUnion(forced.ambiguous)
        }

        var remove: [ApplicationInfo] = []
        var skipped: [String: UninstallTargetResult] = [:]
        for app in targets {
            if ambiguous.contains(app.id) {
                skipped[app.id] = .skippedAmbiguousProcess
            } else if stopped.contains(app.id) {
                remove.append(app)
            } else {
                skipped[app.id] = .skippedStillRunning
            }
        }
        return (remove, skipped)
    }
}
