import Foundation
import MacUpdaterCore

// MARK: - Tap trust
//
// Homebrew 7 ignores formulae, casks and commands from third-party taps the user has not
// trusted, and prints a remedy block into the output of most brew commands. The brew log
// panel answers it with one-click buttons instead of commands to copy into a terminal. Its own
// area: the fix changes the user's Homebrew configuration rather than updating anything, so it
// is planned from install receipts (`TapTrustPlanner`) and runs only on a click — through the
// same write gate, mutex and termination guard as every other brew mutation.
extension ScanStore {
    /// What the brew log panel on the Updates screen needs to plan and run a remedy.
    var tapTrustActions: TapTrustActions {
        TapTrustActions(
            resolve: { await self.tapTrustRemedies(forUntrustedTaps: $0) },
            run: { await self.runTapTrustRemedy($0) }
        )
    }

    /// The remedies for `taps`, as named by the warning in the brew log.
    ///
    /// Install receipts are read off the main actor: deciding needs every cask's and every
    /// keg's receipt, because a receipt — not a token resembling the tap's name — says which
    /// tap a package came from.
    func tapTrustRemedies(forUntrustedTaps taps: [String]) async -> [TapTrustRemedy] {
        guard !taps.isEmpty, let prefix = BinaryLocator().locateBrewPrefix() else { return [] }
        let installed = await Task.detached(priority: .userInitiated) {
            HomebrewInstallReceipts(prefix: prefix).installedPackages()
        }.value
        return TapTrustPlanner.remedies(forUntrustedTaps: taps, installed: installed)
    }

    func runTapTrustRemedy(_ remedy: TapTrustRemedy) async {
        await dependencies.upgrades.performWrite(.tapTrust) {
            await self.runTapTrustRemedyCoordinated(remedy)
        }
    }

    private func runTapTrustRemedyCoordinated(_ remedy: TapTrustRemedy) async {
        guard let model else { return }
        guard UpgradeMutex.shared.acquire() else {
            showBanner(BannerData(variant: .danger, title: tr("Aktualizacja w toku"),
                                  message: tr("Wega właśnie aktualizuje coś w tle. Spróbuj za chwilę.")))
            return
        }
        defer { UpgradeMutex.shared.release() }
        let ticket = MutationGuard.shared.begin(tr("zmiana tapów Homebrew"))
        defer { MutationGuard.shared.end(ticket) }

        brewLog = ProcessEventStream.appendingCapped([TapTrustPlanner.logHeader(for: remedy)], to: brewLog)
        showLog = true
        WegaLog.info(.homebrew, "Uruchamiam: \(remedy.commandLine)")

        var exitCode: Int32 = 0
        var runError: Error?
        do {
            let stream = try model.brewService.events(arguments: remedy.arguments)
            exitCode = try await ProcessEventStream.drain(stream) { chunk in
                brewLog = ProcessEventStream.appendingCapped(ProcessEventStream.lines(from: chunk), to: brewLog)
            }
        } catch {
            brewLog.append("error: \(error.localizedDescription)")
            runError = error
        }

        guard runError == nil, exitCode == 0 else {
            showBanner(BannerData(variant: .danger, title: tr("Nie udało się zmienić tapów"),
                                  message: tr("Sprawdź logi poniżej.")))
            emitActivitySignal(.error)
            let reason = runError?.localizedDescription ?? "kod \(exitCode)"
            WegaLog.error(.homebrew, "\(remedy.commandLine) nieudane (\(reason))")
            return
        }
        brewLog = ProcessEventStream.appendingCapped([TapTrustPlanner.logSuccess(for: remedy)], to: brewLog)
        let title: String
        switch remedy.kind {
        case .untapUnused:
            title = tr("Odpięto nieużywane tapy")
        case .trustInstalledCasks, .trustInstalledFormulae:
            title = tr("Zaufano zainstalowanym pakietom")
        case .trustRequiredCask, .trustRequiredFormula:
            title = tr("Zaufano wskazanej definicji pakietu")
        }
        showBanner(BannerData(variant: .success, title: title, message: trf("Wykonano: %@", remedy.commandLine)))
        emitActivitySignal(.success)
        WegaLog.info(.homebrew, "Wykonano: \(remedy.commandLine)")
    }
}
