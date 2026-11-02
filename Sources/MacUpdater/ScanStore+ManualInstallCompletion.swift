import Foundation
import MacUpdaterCore

extension ScanStore {
    func reportManualInstallSuccess(token: String, appURL: URL) {
        let isDocker = DockerDesktopUpdatePolicy.isDocker(token: token)
        if isDocker {
            let installation = InstallationIdentity(path: appURL)
            manualOutdated.removeAll {
                DockerDesktopUpdatePolicy.isDocker($0) && InstallationIdentity(path: $0.path) == installation
            }
            vendorHandoffs.removeAll { InstallationIdentity(path: $0.path) == installation }
            vendorMessages[appURL.path] = nil
            brewOutdated?.casks.removeAll { $0.name == token }
            queueDockerRestart(token: token, bundleURL: appURL)
        }
        manualOutdated.removeAll {
            if case .cask(let t) = $0.source { return t == token }
            return false
        }
        showBanner(BannerData(variant: .success, title: trf("Zaktualizowano %@", "\(token)"),
                              message: isDocker
                                ? tr("Pakiety zainstalowane. Gotowość silnika Docker nie była sprawdzana.")
                                : tr("Teraz zarządzany przez Homebrew.")))
        emitActivitySignal(.success)
        emitWegaState(WegaState(pose: .happy, line: trf("%@ zaktualizowany i pod opieką Brew.", "\(token)")))
        WegaLog.info(.homebrew, "Zainstalowano \(token) (brew cask)")
    }
}
