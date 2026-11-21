import Foundation
import MacUpdaterCore

/// UXP-11 — a rule change the user can take back at once: the line the toast says, the key the
/// change wrote and the entry that key held before (`nil` when it held none).
struct RuleUndoNotice: Equatable, Identifiable {
    let id: UUID
    let message: String
    let key: String
    let previous: UpdatePolicyEntry?
}

// MARK: - Rule undo (UXP-11)
//
// "Nie aktualizuj" and "Pomiń tę wersję" hide a row at once. The toast that follows takes the
// change back; it brings the row back to the list and never into the queue.
extension ScanStore {
    /// Offers "Cofnij" for the rule just written under `key`. A write that changed nothing
    /// offers nothing, so the toast never claims a change that did not happen.
    func noteRuleChange(key: String, previous: UpdatePolicyEntry?, message: String) {
        guard UpdatePolicyStore.shared.entries[key] != previous else { return }
        ruleUndo = RuleUndoNotice(id: UUID(), message: message, key: key, previous: previous)
    }

    /// Puts back the rule the last change replaced (a pin that existed before a skip returns),
    /// or removes the new rule when there was none. `selected` is left as it is.
    func undoRuleChange() {
        guard let notice = ruleUndo else { return }
        ruleUndo = nil
        if let previous = notice.previous {
            UpdatePolicyStore.shared.restore(previous)
        } else {
            UpdatePolicyStore.shared.remove(key: notice.key)
        }
    }

    func dismissRuleUndo() {
        ruleUndo = nil
    }
}
