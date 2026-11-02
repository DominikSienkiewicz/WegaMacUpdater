import Foundation
import MacUpdaterCore

extension ScanStore {
    func queueDockerRestart(token: String, bundleURL: URL) {
        guard DockerDesktopMutationGate.isDocker(token: token) else { return }
        let existing = restartCandidates.first {
            restartDockerBundleURLs[$0.processName]?.standardizedFileURL == bundleURL.standardizedFileURL
        }
        let candidate = existing ?? RestartInfo(
            processName: "Docker Desktop", appName: bundleURL.deletingPathExtension().lastPathComponent
        )
        restartCandidates.removeAll { $0.processName == candidate.processName }
        restartCandidates.append(candidate)
        restartDockerBundleURLs[candidate.processName] = bundleURL
        restartDiagnosticOperationIDs.removeValue(forKey: candidate.processName)
    }

    func dockerRestartBundles(
        tokens: [String], appPaths: [String: URL], running: [RunningApplicationTarget]
    ) -> [String: URL] {
        var bundles: [String: URL] = [:]
        for token in tokens where DockerDesktopMutationGate.isDocker(token: token) {
            guard let bundleURL = appPaths[token] else { continue }
            let candidates = RunningCaskDetector.runningApps(
                tokens: [token], appPaths: appPaths, running: running, overrides: MacUpdaterConstants.restartMap
            )
            for candidate in candidates { bundles[candidate.processName] = bundleURL }
        }
        return bundles
    }

    func dockerInstallationMessage(in summary: UpdateRunSummary) -> String? {
        guard summary.upgraded.contains(where: { $0.kind == .cask && DockerDesktopMutationGate.isDocker(token: $0.name) }) else {
            return nil
        }
        return tr("Pakiety zainstalowane. Gotowość silnika Docker nie była sprawdzana.")
    }

    func handleDockerRestart(_ info: RestartInfo, fields: [String: String]) async -> Bool {
        let bundleURL = restartDockerBundleURLs[info.processName]
        let dockerName = [info.appName.lowercased(), info.processName.lowercased()]
            .contains { ["docker", "docker desktop"].contains($0) }
        guard bundleURL != nil || dockerName else { return false }
        guard restartBusy == nil, !updating else { return true }
        restartBusy = info.processName
        defer { restartBusy = nil }

        let result: DockerDesktopRestartResult
        if let bundleURL {
            result = await dependencies.restartDocker(bundleURL)
        } else {
            result = .unknown(tr("Nie ustalono ścieżki aplikacji Docker. Sprawdź aktualizacje ponownie lub uruchom Docker ręcznie."))
        }
        let feedback = dockerRestartFeedback(result)
        let resultFields = fields.merging([
            "result": feedback.code,
            "engineReadiness": result.engineReady ? "ready" : "notConfirmed",
        ], uniquingKeysWith: { _, new in new })
        UpdateDiagnostics.record("restart.dockerResult", fields: resultFields)
        if result.engineReady {
            restartCandidates.removeAll { $0.processName == info.processName }
            restartDiagnosticOperationIDs.removeValue(forKey: info.processName)
            restartDockerBundleURLs.removeValue(forKey: info.processName)
            UpdateDiagnostics.record("restart.flowCompleted", fields: resultFields)
        }
        showBanner(BannerData(
            variant: result.engineReady ? .success : .danger,
            title: result.engineReady ? tr("Silnik Docker gotowy") : tr("Nie potwierdzono gotowości silnika Docker"),
            message: feedback.message
        ))
        return true
    }

    private func dockerRestartFeedback(_ result: DockerDesktopRestartResult) -> (code: String, message: String) {
        switch result {
        case .ready:
            return ("ready", tr("Lokalny silnik Docker odpowiada. Wynik instalacji jest raportowany osobno."))
        case .stopFailed(let detail):
            return ("stopFailed", trf("Nie udało się bezpiecznie zatrzymać Docker Desktop. %@", detail))
        case .startFailed(let detail):
            return ("startFailed", trf("Nie udało się uruchomić Docker Desktop. %@", detail))
        case .readinessTimedOut(let detail):
            return ("readinessTimedOut", trf("Minął limit oczekiwania na lokalny silnik Docker. Wynik instalacji pozostaje bez zmian. %@", detail))
        case .unknown(let detail):
            return ("unknown", detail)
        case .cancelled:
            return ("cancelled", tr("Oczekiwanie anulowane. Stan silnika Docker nie został potwierdzony; wynik instalacji pozostaje bez zmian."))
        }
    }
}
