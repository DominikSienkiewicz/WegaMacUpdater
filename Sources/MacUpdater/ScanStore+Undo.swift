import Foundation
import MacUpdaterCore

// MARK: - LT-01 — „Cofnij aktualizację”
//
// The manual undo half of `ScanStore`, split out of `ScanStore+Actions.swift` (file
// length). The journaled phases and the retention sweep live in
// `MacUpdaterCore.UpdateOperationStore`; this is the UI-facing action that turns a
// retained snapshot back into the installed app — and pins it, so the update the user
// just took back is not offered again on the next scan.
extension ScanStore {

    /// Re-reads which committed updates can still be undone. Cheap (a directory walk of a
    /// handful of journals) and called after every run, undo and appearance, so the
    /// section never shows an undo whose snapshot the retention sweep already removed.
    func refreshUndoableUpdates() {
        undoableUpdates = dependencies.undoableUpdates()
    }

    /// The manual undo LT-01 exists for: put the retained pre-upgrade snapshot back over
    /// the current app, then pin the restored version so Wega does not immediately offer
    /// the same update again ("nowa wersja psuje mój workflow" — the user has said so,
    /// out loud, by pressing the button).
    func undoUpdate(_ undoable: UndoableUpdate) async {
        guard undoBusy == nil else { return }
        undoBusy = undoable.token
        defer { undoBusy = nil }
        do {
            try await dependencies.upgrades.performWriteLease(.foregroundUpgrade) { lease in
                await self.undoUpdateCoordinated(undoable, operationLease: lease)
            }
        } catch {
            WegaLog.error(.homebrew, "Cofanie aktualizacji: \(error.localizedDescription)")
        }
        refreshUndoableUpdates()
    }

    private func undoUpdateCoordinated(
        _ undoable: UndoableUpdate,
        operationLease: OperationCoordinator.Lease
    ) async {
        let store = UpdateOperationStore.shared
        guard let (operation, item) = store.operationAndItem(
            operationID: undoable.operationID, token: undoable.token
        ), item.phase == .committed, let snapshotName = item.snapshotName else {
            WegaLog.error(.homebrew, "\(undoable.token): cofanie pominięte — operacja nie jest już do cofnięcia.")
            return
        }
        let snapshotURL = store.snapshotURL(operationID: operation.id, name: snapshotName)
        let appURL = URL(fileURLWithPath: item.appPath)
        guard FileManager.default.fileExists(atPath: snapshotURL.path),
              FileManager.default.fileExists(atPath: appURL.path) else {
            WegaLog.error(.homebrew, "\(undoable.token): cofanie pominięte — brak snapshotu albo aplikacji.")
            return
        }
        // The restore must land on the same app the snapshot was taken from — a bundle-ID
        // mismatch means the app at the recorded path is no longer that app.
        let currentBundleID = Bundle(url: appURL)?.infoDictionary?["CFBundleIdentifier"] as? String
        if let expected = item.bundleIdentifier, currentBundleID != expected {
            showBanner(BannerData(variant: .danger, title: tr("Cofanie przerwane"),
                                  message: trf("%@: aplikacja pod %@ to już nie ta sama aplikacja.", "\(undoable.token)", "\(item.appPath)")))
            WegaLog.error(.homebrew, "\(undoable.token): cofanie przerwane — identyfikator bundle zmienił się (\(expected) → \(currentBundleID ?? "—")).")
            return
        }

        guard await CaskRollbackGuard.restoreSnapshot(snapshotURL, to: appURL) else {
            showBanner(BannerData(variant: .danger, title: tr("Cofanie się nie powiodło"),
                                  message: trf("%@: nie udało się przywrócić poprzedniej wersji — szczegóły w logu.", "\(undoable.token)"),
                                  action: .openLogs))
            WegaLog.error(.homebrew, "\(undoable.token): cofanie aktualizacji nie powiodło się.")
            return
        }

        let restoredVersion = (Bundle(url: appURL)?.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? item.preUpgradeVersion
        store.markUndoneByUser(operationID: operation.id, token: undoable.token)
        // Auto-pin (LT-01): the restored version is held until the user lifts the pin —
        // otherwise the very next scan would offer the update they just undid.
        if let restoredVersion, !restoredVersion.isEmpty {
            UpdatePolicyStore.shared.pin(
                key: UpdatePlanner.key(name: undoable.token, kind: .cask),
                name: undoable.token,
                version: restoredVersion
            )
        }
        WegaLog.info(.homebrew, "\(undoable.token): cofnięto aktualizację na życzenie użytkownika (wersja \(restoredVersion ?? "—")), przypięto przywróconą wersję.")
        showBanner(BannerData(
            variant: .success,
            title: trf("Cofnięto aktualizację: %@", "\(undoable.token)"),
            message: restoredVersion.map {
                trf("Przywrócono wersję %@ i przypięto ją — Wega nie zaproponuje nowszej, dopóki nie odepniesz.", "\($0)")
            } ?? tr("Przywrócono poprzednią wersję.")
        ))
        emitWegaState(WegaState(pose: .happy, line: trf("Cofnęłam %@ do wersji %@.", "\(undoable.token)", "\(restoredVersion ?? "—")")))
        await runCheck(emitActivity: false, lightweight: true, operationLease: operationLease)
    }
}
