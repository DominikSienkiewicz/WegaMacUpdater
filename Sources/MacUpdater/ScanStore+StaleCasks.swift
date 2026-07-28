import Foundation
import MacUpdaterCore

// MARK: - Stale cask cleanup
//
// ARCH-08 — Homebrew's leftover cask entries, removed only with the user's consent (M3b). Its
// own area: it is maintenance the scan surfaces rather than part of any update, and REL-13's
// honest-outcome rule lives here.
extension ScanStore {
    func cleanUpStaleCasks() async {
        await UpgradeCoordinator.shared.performWrite(.cleanup) {
            await self.cleanUpStaleCasksCoordinated()
        }
    }

    private func cleanUpStaleCasksCoordinated() async {
        guard let model, !cleaningStaleCasks, !staleCasks.isEmpty else { return }
        let ticket = MutationGuard.shared.begin(tr("czyszczenie Homebrew"))
        defer { MutationGuard.shared.end(ticket) }
        cleaningStaleCasks = true
        defer { cleaningStaleCasks = false }

        var removed: [String] = []
        var failed: [String] = []
        for token in staleCasks {
            if (try? await model.brewService.uninstallCask(token: token, force: true)) != nil {
                removed.append(token)
            } else {
                failed.append(token)
                WegaLog.error(.homebrew, "Nie udało się usunąć nieaktualnego casku: \(token)")
            }
        }
        staleCasks.removeAll { removed.contains($0) }
        if !removed.isEmpty {
            WegaLog.info(.homebrew, "Usunięto nieaktualne caski: \(removed.joined(separator: ", "))")
        }
        // REL-13 — the banner reflects the real result: a full failure ("Usunięto 0") is no
        // longer dressed up as success, and a partial sweep says so.
        let outcome = StaleCaskCleanupOutcome.classify(removed: removed.count, failed: failed.count)
        showBanner(StaleCaskCleanupPresentation.banner(for: outcome))
    }

    /// The user does not want to clean up now. Drop the card for this scan.
    func dismissStaleCasks() {
        staleCasks = []
    }
}
