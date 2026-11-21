import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UXP-16 — one card that says what Wega does with root, the network and the user's data.
@Suite("What Wega does") @MainActor
struct TrustSettingsCardTests {
    @Test func theCardSaysWhatHappensToRootNetworkAndData() {
        withLanguage(.en) {
            #expect(tr("Sprawdzanie aktualizacji niczego nie instaluje ani nie usuwa — odświeża tylko katalog Homebrew. Wyjątek to aplikacje, którym pozwolisz aktualizować się w tle.")
                    == "Checking for updates installs and removes nothing — it only refreshes Homebrew's catalog. The exception is apps you allow to update in the background.")
            #expect(tr("Wega nie wysyła nic o Tobie: nie ma telemetrii ani analityki.") == "Wega sends nothing about you: no telemetry, no analytics.")
            #expect(tr("Łączy się z GitHubem (katalog aplikacji, aktualizacje Wegi), producentami zainstalowanych aplikacji, Homebrew i App Store.")
                    == "It connects to GitHub (app catalog, Wega updates), the developers of apps you have installed, Homebrew and the App Store.")
            #expect(tr("Raport błędu przejrzysz przed otwarciem poczty albo GitHuba.") == "You can review a problem report before opening email or GitHub.")
            #expect(tr("Pokaż stałe adresy") == "Show Fixed Addresses")
            #expect(tr("Do tego adresy aktualizacji zapisane w zainstalowanych aplikacjach, rejestr npm i serwery App Store.") == "Plus the update addresses stored in your installed apps, the npm registry and App Store servers.")
        }
        let english = Translations.en.values.joined(separator: "\n")
        #expect(!english.contains("nothing leaves your Mac") && !english.contains("Nothing leaves your Mac"))
    }

    @Test func everyPermissionSaysWhyWhatIfNotAndHowToUndo() {
        let all = PermissionExplanation.all(appManagement: .unknown)
        #expect(all.count == 4)
        withLanguage(.pl) {
            #expect(all.map(\.title) == [tr("Pomocnik Wegi"), tr("Touch ID dla poleceń administratora"), tr("Zarządzanie aplikacjami"), tr("Pełny dostęp do dysku")])
            #expect(PermissionExplanation.all(appManagement: .unknown)[2].text.hasSuffix("Nie znam jeszcze stanu uprawnienia Zarządzanie aplikacjami."))
            #expect(PermissionExplanation.all(appManagement: .denied)[2].text.hasSuffix("Stan: odmowa"))
            #expect(PermissionExplanation.all(appManagement: .granted)[2].text.hasSuffix("Stan: przyznane"))
        }
        #expect(PermissionExplanation.all(appManagement: .granted, touchIDSupported: false).map(\.kind) == [.helper, .appManagement, .fullDiskAccess], "no Touch ID entry where the Touch ID card is hidden")
        #expect(PermissionExplanation.all(appManagement: .granted).map(\.kind) == [.helper, .touchID, .appManagement, .fullDiskAccess])
        withLanguage(.en) {
            #expect(tr("Stan: %@") == "Status: %@")
            #expect(tr("Nie znam jeszcze stanu uprawnienia Zarządzanie aplikacjami.") == "App Management permission status is not known yet.")
        }
    }

    @Test func thePermissionsTabOpensWithTheCardAndTheHelperDropsTheJargon() throws {
        let info = try source("Sources/MacUpdater/InfoView.swift")
        #expect(info.contains("TrustSettingsCard(appManagement: diagnostics?.appManagement, touchIDSupported: touchIDState != .notSupported)"))
        #expect(info.contains(".id(SettingsCard.trust)"))
        #expect(!info.contains("(XPC) z białą listą"))
        #expect(info.contains("tr(\"Pomocnik Wegi działa jako root i umie tylko cztery rzeczy:"))
        #expect(info.contains("tr(\"Działa też w Terminalu, nie tylko w Wedze.\")"))
        let card = try source("Sources/MacUpdater/TrustSettingsCard.swift")
        #expect(card.contains("WegaDisclosure") && card.contains("AppEndpoints.shared.connectionHosts"))
        #expect(!card.contains("DisclosureGroup"))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }
}
