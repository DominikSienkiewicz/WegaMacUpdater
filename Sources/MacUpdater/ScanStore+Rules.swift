import Foundation
import MacUpdaterCore

/// UXP-11 — a rule change the user can take back at once: the line the toast says, the key the
/// change wrote, the entry that key held before (`nil` when it held none) and the entry the
/// change left there.
struct RuleUndoNotice: Equatable, Identifiable {
    let id: UUID
    let message: String
    let key: String
    let previous: UpdatePolicyEntry?
    let written: UpdatePolicyEntry
}

// MARK: - Rule undo (UXP-11)
//
// "Nie aktualizuj" and "Pomiń tę wersję" hide a row at once. The toast that follows takes the
// change back; it brings the row back to the list and never into the queue.
extension ScanStore {
    /// Offers "Cofnij" for the rule just written under `key`, and says the toast's line to
    /// VoiceOver as it appears. A write that changed nothing offers nothing, so the toast never
    /// claims a change that did not happen.
    func noteRuleChange(key: String, previous: UpdatePolicyEntry?, message: String) {
        guard let written = UpdatePolicyStore.shared.entries[key], written != previous else { return }
        ruleUndo = RuleUndoNotice(id: UUID(), message: message, key: key, previous: previous, written: written)
        announcer.announce(message)
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

    /// Closes the toast only while it is still the one `id` names, so the countdown or the close
    /// button of a toast that has since been replaced never closes the newer one.
    func dismissRuleUndo(id: RuleUndoNotice.ID) {
        guard ruleUndo?.id == id else { return }
        dismissRuleUndo()
    }

    /// Closes the toast once the rule under its key is no longer the one its change wrote — a
    /// "Przywróć" in the sheet or in Settings — so "Cofnij" never puts an older rule back over
    /// the user's own edit. Fed every change of the policy store.
    func dropRuleUndo(ifStaleIn entries: [String: UpdatePolicyEntry]) {
        guard let notice = ruleUndo, entries[notice.key] != notice.written else { return }
        ruleUndo = nil
    }
}
