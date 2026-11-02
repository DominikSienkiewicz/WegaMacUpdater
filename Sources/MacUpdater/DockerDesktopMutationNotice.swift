import Foundation
import MacUpdaterCore

extension DockerDesktopStopResult {
    var mutationBlockMessage: String {
        switch self {
        case .stopped:
            return tr("Docker Desktop został zatrzymany.")
        case .unsupported:
            return tr("Nie można bezpiecznie zatrzymać tej wersji Docker Desktop. Zamknij ją ręcznie i spróbuj ponownie.")
        case .timedOut:
            return tr("Docker Desktop nie zakończył pracy w wyznaczonym czasie. Podmiana aplikacji została wstrzymana.")
        case .cancelled:
            return tr("Zatrzymywanie Docker Desktop anulowano. Podmiana aplikacji została wstrzymana.")
        case .failed:
            return tr("Nie potwierdzono zatrzymania Docker Desktop. Podmiana aplikacji została wstrzymana — szczegóły w logu.")
        }
    }
}

extension ScanStore {
    func dockerMutationFailure(token: String, bundleURL: URL?) async -> BrewUpgradeOutcome? {
        guard let shutdown = await DockerDesktopMutationGate.stopIfNeeded(
            token: token, bundleURL: bundleURL, stop: dependencies.stopDocker
        ), !shutdown.allowsBundleMutation else { return nil }
        let message = shutdown.mutationBlockMessage
        brewLog.append("⏸ " + message)
        WegaLog.error(.homebrew, "\(token): \(message) (\(shutdown))")
        showBanner(BannerData(variant: .danger, title: tr("Aktualizacja odroczona"), message: message, action: .openLogs))
        emitActivitySignal(.error)
        return BrewUpgradeOutcome(exitCode: -1, failedTokens: [token], errorLines: [message])
    }
}
