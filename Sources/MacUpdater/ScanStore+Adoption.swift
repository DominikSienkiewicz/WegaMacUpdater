import Foundation
import MacUpdaterCore

// MARK: - Manual cask adoption
//
// ARCH-08 — "Aktualizuj przez Brew": taking an app Homebrew did not install and putting it
// under a cask, through the same protected transaction an ordinary upgrade uses. Separate from
// the update path because it starts from a different question — not "is there a newer version"
// but "is this app the cask it looks like" — and REL-08 and LT-03 both live here.
extension ScanStore {
    func installManual(token: String) async {
        await UpgradeCoordinator.shared.performWrite(.manualInstall) {
            await self.installManualCoordinated(token: token)
        }
    }

    private func installManualCoordinated(token: String) async {
        guard let model, manualBusy == nil else { return }
        guard UpgradeMutex.shared.acquire() else {
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja w toku"),
                                  message: tr("Wega właśnie aktualizuje coś w tle. Spróbuj za chwilę.")))
            return
        }
        defer { UpgradeMutex.shared.release() }
        manualBusy = token
        defer { manualBusy = nil }
        let ticket = MutationGuard.shared.begin(trf("instalacja %@", "\(token)"))
        defer { MutationGuard.shared.end(ticket) }
        emitActivitySignal(.scanning)
        let installArgs = BrewService.adoptCaskArguments(token: token)
        brewLog = ["$ brew " + installArgs.joined(separator: " ")]
        showLog = true
        WegaLog.info(.homebrew, "Uruchamiam: brew \(installArgs.joined(separator: " "))")
        emitWegaState(WegaState(pose: .sniff, line: trf("Instaluję %@ przez Brew…", "\(token)")))

        guard let appURL = manualOutdated.first(where: {
            if case .cask(let candidate) = $0.source { return candidate == token }
            return false
        })?.path else {
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja odroczona"),
                                  message: tr("Nie udało się utworzyć wymaganego snapshotu.")))
            emitActivitySignal(.error)
            return
        }

        let preparation: CaskReplacementSafety.Preparation
        switch await CaskReplacementSafety.prepare(
            token: token,
            appURL: appURL,
            brewService: model.brewService
        ) {
        case .ready(let ready):
            preparation = ready
        case .resourcePostponed(let reason):
            brewLog.append("⏸ " + trf("Aktualizacja odroczona: %@.", "\(reason)"))
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja odroczona"),
                                  message: trf("Bramka zasobów: %@.", "\(reason)")))
            emitActivitySignal(.error)
            return
        case .publisherRejected(let old, let new):
            let message = trf("%@: Team ID zmienił się (%@ → %@). Zweryfikuj.",
                              "\(token)", "\(old)", "\(new ?? "—")")
            brewLog.append("⏸ " + message)
            showBanner(BannerData(variant: .danger, title: tr("Zmiana wydawcy"), message: message))
            emitActivitySignal(.error)
            return
        case .snapshotFailed:
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja odroczona"),
                                  message: tr("Nie udało się utworzyć wymaganego snapshotu.")))
            emitActivitySignal(.error)
            return
        }

        var installError: Error?
        var exitCode: Int32 = 0
        // LT-01 — the journal's last word before brew replaces the bundle: a crash from
        // here on reads as "disk state unknown" at the next launch.
        preparation.operation.recordInstalling()
        do {
            let stream = try model.brewService.events(arguments: installArgs)
            exitCode = try await ProcessEventStream.drain(stream) { chunk in
                brewLog = ProcessEventStream.appendingCapped(ProcessEventStream.lines(from: chunk), to: brewLog)
            }
        } catch {
            brewLog.append("error: \(error.localizedDescription)")
            installError = error
        }

        let installedAppURL = await CaskReplacementSafety.resolveInstalledAppURL(
            preparation,
            brewService: model.brewService
        )
        let verification = await CaskReplacementSafety.verify(
            preparation,
            installedAppURL: installedAppURL
        )
        guard reportManualReplacementVerification(verification, token: token) else { return }

        if let installError {
            // UX-07 — the raw, English error text goes to the log below; the banner shows
            // a short, translated line and points there via "Zobacz w logach".
            showBanner(BannerData(variant: .danger, title: tr("Błąd instalacji"),
                                  message: tr("Nie udało się dokończyć instalacji — szczegóły w logu."),
                                  action: .openLogs))
            emitActivitySignal(.error)
            emitWegaState(WegaState(pose: .idle, line: trf("Coś poszło nie tak z %@.", "\(token)")))
            WegaLog.error(.homebrew, "Instalacja \(token): \(installError.localizedDescription)")
        } else if exitCode == 0 {
            manualOutdated.removeAll {
                if case .cask(let t) = $0.source { return t == token }
                return false
            }
            showBanner(BannerData(variant: .success, title: trf("Zaktualizowano %@", "\(token)"),
                                  message: tr("Teraz zarządzany przez Homebrew.")))
            emitActivitySignal(.success)
            emitWegaState(WegaState(pose: .happy, line: trf("%@ zaktualizowany i pod opieką Brew.", "\(token)")))
            WegaLog.info(.homebrew, "Zainstalowano \(token) (brew cask)")
        } else {
            showBanner(BannerData(variant: .danger, title: trf("Błąd instalacji %@", "\(token)"),
                                  message: tr("Sprawdź logi poniżej.")))
            emitActivitySignal(.error)
            emitWegaState(WegaState(pose: .idle, line: trf("Coś poszło nie tak z %@.", "\(token)")))
            let reason = ScanLog.brewErrorReason(from: brewLog).map { ": \($0)" } ?? ""
            WegaLog.error(.homebrew, "Instalacja \(token) nieudana (kod \(exitCode))\(reason)")
        }
    }

    private func reportManualReplacementVerification(
        _ verdict: CaskValidationVerdict,
        token: String
    ) -> Bool {
        let title: String
        let message: String
        switch verdict {
        case .healthy:
            return true
        case .rolledBack:
            title = tr("Aktualizacja niekompletna")
            message = trf("%@: nowa wersja nie przeszła kontroli — przywrócono poprzednią.", "\(token)")
        case .rollbackFailed:
            title = tr("Rollback się nie powiódł")
            message = trf(
                "%@: nowa wersja nie przeszła kontroli, a przywrócenie poprzedniej nie powiodło się. Sprawdź aplikację przed użyciem.",
                "\(token)"
            )
        case .publisherChanged(let old, let new):
            title = tr("Zmiana wydawcy")
            message = trf("%@: Team ID zmienił się (%@ → %@). Zweryfikuj.",
                          "\(token)", "\(old)", "\(new ?? "—")")
        case .publisherChangedAndRolledBack(let old, let new):
            title = tr("Zmiana wydawcy")
            message = trf("%@: Team ID zmienił się (%@ → %@). Przywrócono poprzednią zaufaną wersję.",
                          "\(token)", "\(old)", "\(new ?? "—")")
        }
        brewLog.append("⚠️ " + message)
        showBanner(BannerData(variant: .danger, title: title, message: message))
        emitActivitySignal(.error)
        emitWegaState(WegaState(pose: .alert, line: trf("Coś poszło nie tak z %@.", "\(token)")))
        WegaLog.error(.homebrew, message)
        return false
    }
}
