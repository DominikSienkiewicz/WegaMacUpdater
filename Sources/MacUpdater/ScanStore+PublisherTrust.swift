import AppKit
import Foundation
import MacUpdaterCore

// MARK: - Accepting a publisher change
//
// The watchdog refuses any cask whose Team ID differs from the trusted baseline, and the ledger
// never overwrites that baseline on its own. A vendor that legitimately moves to a new Developer
// ID (Proton Mail: 6UN54H93QT → 2SB5Z68H26) was therefore stuck for good: vetoed on every run,
// listed as "cofnięto — ponów próbę" at the version it already had. This is the way out, and it
// is the user's to take: an explicit confirmation, checked against a fresh read of the bundle.
extension ScanStore {
    /// What the publisher-change confirmation shows the user.
    struct PublisherChangePrompt: Equatable {
        let token: String
        let previousTeamID: String?
        let newTeamID: String
    }

    /// The action a publisher warning about `outcome` offers, or `nil` for anything but a cask.
    func trustPublisherAction(for outcome: ItemUpdateOutcome, teamID: String?) -> BannerAction? {
        guard outcome.kind == .cask else { return nil }
        return .trustPublisher(token: outcome.name, teamID: teamID)
    }

    func trustNewPublisher(token: String, reportedTeamID: String?) async {
        guard let appURL = installedAppURL(forCask: token) else {
            showBanner(BannerData(variant: .danger, title: tr("Nie zmieniono zaufania"),
                                  message: trf("%@: nie znaleziono zainstalowanej aplikacji.", "\(token)")))
            return
        }
        let installedTeamID = await dependencies.teamIDOfApp(appURL)
        let ledger = dependencies.teamIDLedger
        let keys = [TeamIDLedger.caskKey(token)] + [dependencies.bundleIdentifierOfApp(appURL)].compactMap { $0 }
        let decision = PublisherChangeAcceptance.decide(
            reportedTeamID: reportedTeamID,
            installedTeamID: installedTeamID,
            trustedTeamIDs: keys.map { ledger.teamID(forBundleID: $0) }
        )

        switch decision {
        case .accept(let previous, let new):
            let prompt = PublisherChangePrompt(token: token, previousTeamID: previous, newTeamID: new)
            guard dependencies.confirmPublisherChange(prompt) else { return }
            ledger.acceptPublisherChange(keys: keys, teamID: new)
            dependencies.rollbackLedger.clear(token: token)
            dropRowsSettledByPublisherTrust(token: token)
            WegaLog.warning(.homebrew, "\(token): użytkownik zaakceptował nowego wydawcę (\(previous ?? "—") → \(new)).")
            showBanner(BannerData(variant: .success, title: tr("Zaufano nowemu wydawcy"),
                                  message: trf("%@: Team ID %@ jest teraz zaufanym wydawcą.", "\(token)", "\(new)")))
        case .alreadyTrusted:
            showBanner(BannerData(variant: .success, title: tr("Wydawca już zaufany"),
                                  message: trf("%@: zainstalowana aplikacja jest podpisana zaufanym Team ID.", "\(token)")))
        case .signatureUnreadable:
            showBanner(BannerData(variant: .danger, title: tr("Nie zmieniono zaufania"),
                                  message: trf("%@: nie udało się odczytać podpisu zainstalowanej aplikacji.", "\(token)")))
        case .installedDiffersFromReport(let reported, let installed):
            WegaLog.error(.homebrew, "\(token): podpis zmienił się od ostrzeżenia (\(reported) → \(installed)) — nie zmieniono zaufania.")
            showStickyBanner(BannerData(variant: .danger, title: tr("Zmiana wydawcy"),
                                        message: trf("%@: aplikację podpisano ponownie innym Team ID (%@ zamiast %@). Nie zmieniono zaufania.",
                                                     "\(token)", "\(installed)", "\(reported)")))
        }
    }

    private func installedAppURL(forCask token: String) -> URL? {
        let row = manualOutdated.first {
            if case .cask(let candidate) = $0.source { return candidate == token }
            return false
        }
        return row?.path ?? caskIconPaths[token]
    }

    /// A row kept on the list only by the rolled-back mark, at the version the cask already
    /// offers, has nothing left to update once its publisher is trusted.
    private func dropRowsSettledByPublisherTrust(token: String) {
        manualOutdated.removeAll {
            guard case .cask(let candidate) = $0.source, candidate == token, $0.rolledBack else { return false }
            return $0.installedVersion != nil && $0.installedVersion == $0.availableVersion
        }
        for index in manualOutdated.indices {
            if case .cask(let candidate) = manualOutdated[index].source, candidate == token {
                manualOutdated[index].rolledBack = false
            }
        }
        emitCounts()
    }
}

enum PublisherChangeAlert {
    @MainActor
    static func confirm(_ prompt: ScanStore.PublisherChangePrompt) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = trf("Zaufać nowemu wydawcy %@?", "\(prompt.token)")
        alert.informativeText = trf(
            "Teraz podpisuje ją Team ID %@ zamiast zaufanego %@. Potwierdź tylko, jeśli wiesz, że producent zmienił konto deweloperskie.",
            "\(prompt.newTeamID)", "\(prompt.previousTeamID ?? "—")"
        )
        alert.addButton(withTitle: tr("Anuluj"))
        alert.addButton(withTitle: tr("Zaufaj nowemu wydawcy"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
