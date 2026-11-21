import AppKit
import MacUpdaterCore
import SwiftUI

/// One permission Wega asks for, in the three things a user decides on: why it is needed,
/// what happens without it, and how to take it back (UXP-16).
struct PermissionExplanation: Equatable, Identifiable {
    enum Kind: Equatable { case helper, touchID, appManagement, fullDiskAccess }

    let kind: Kind
    let title: String
    let text: String
    var id: String { title }

    static func all(appManagement: AppManagementPermission?, touchIDSupported: Bool = true) -> [PermissionExplanation] {
        let entries = [
            PermissionExplanation(
                kind: .helper,
                title: tr("Pomocnik Wegi"),
                text: tr("Pomocnik Wegi działa jako root i umie tylko cztery rzeczy: zainstalować zweryfikowany pakiet Wegi, włączyć albo wyłączyć Touch ID dla sudo, przywrócić kopię aplikacji sprzed aktualizacji, przenieść do Kosza aplikację należącą do roota. Przy każdym połączeniu sprawdza podpis Wegi. Jest opcjonalny.")
                    + " " + tr("Bez niego Wega poprosi o hasło. Wyłączysz go przyciskiem „Usuń pomocnika”.")),
            PermissionExplanation(
                kind: .touchID,
                title: tr("Touch ID dla poleceń administratora"),
                text: tr("Zastępuje hasło administratora odciskiem palca w poleceniach sudo, także w Terminalu. Bez niego wpisujesz hasło. Wyłączysz je w karcie Touch ID, gdy pomocnik Wegi jest zainstalowany, albo ręcznie według przewodnika.")),
            PermissionExplanation(
                kind: .appManagement,
                title: tr("Zarządzanie aplikacjami"),
                text: tr("macOS pyta o nie, gdy Wega podmienia aplikację w /Applications. Bez niego aktualizacje aplikacji się nie udadzą. Zmienisz to w Ustawieniach systemowych → Prywatność i bezpieczeństwo.")
                    + " " + appManagementState(appManagement)),
            PermissionExplanation(
                kind: .fullDiskAccess,
                title: tr("Pełny dostęp do dysku"),
                text: tr("Potrzebny tylko mapie „Pliki i foldery” w Porządkach; dostają go też procesy uruchamiane przez Wegę. Bez niego mapa jest niepełna. Odbierzesz go w Ustawieniach systemowych → Prywatność i bezpieczeństwo.")),
        ]
        return touchIDSupported ? entries : entries.filter { $0.kind != .touchID }
    }

    private static func appManagementState(_ permission: AppManagementPermission?) -> String {
        switch permission {
        case .denied:  trf("Stan: %@", tr("odmowa"))
        case .granted: trf("Stan: %@", tr("przyznane"))
        case .unknown, nil: tr("Nie znam jeszcze stanu uprawnienia Zarządzanie aplikacjami.")
        }
    }
}

/// UXP-16 — what Wega does with root, the network and the user's data, in one card at the top
/// of the permissions tab. Every sentence is a claim about the code; the full list of hosts is
/// read from `endpoints.json`, so it cannot drift from what Wega actually contacts.
struct TrustSettingsCard: View {
    let appManagement: AppManagementPermission?
    var touchIDSupported = true
    @State private var showsHosts = false

    var body: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "checkmark.shield", title: tr("Co Wega robi"))
                VStack(alignment: .leading, spacing: 14) {
                    permissions
                    connections
                    localData
                }
                .padding(14)
            }
        }
    }

    private var permissions: some View {
        section(tr("Uprawnienia")) {
            ForEach(PermissionExplanation.all(appManagement: appManagement, touchIDSupported: touchIDSupported)) { permission in
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title).font(.wega(.callout, weight: .semibold))
                    paragraph(permission.text)
                    if permission.kind == .touchID {
                        Link(tr("Jak wyłączyć Touch ID dla sudo"), destination: AppEndpoints.shared.touchIDGuideURL)
                            .font(.wega(.subheadline))
                    }
                    if permission.kind == .appManagement, appManagement == .denied {
                        Button(tr("Otwórz ustawienia prywatności")) {
                            NSWorkspace.shared.open(AppManagementSettings.paneURL)
                        }
                        .buttonStyle(.link)
                        .font(.wega(.subheadline))
                    }
                }
            }
        }
    }

    private var connections: some View {
        section(tr("Połączenia")) {
            paragraph(tr("Sprawdzanie aktualizacji niczego nie instaluje ani nie usuwa — odświeża tylko katalog Homebrew. Wyjątek to aplikacje, którym pozwolisz aktualizować się w tle."))
            paragraph(tr("Wega nie wysyła nic o Tobie: nie ma telemetrii ani analityki."))
            paragraph(tr("Producentom wysyła tylko to, czego wymaga sprawdzenie, np. numer zainstalowanej wersji."))
            paragraph(tr("Łączy się z GitHubem (katalog aplikacji, aktualizacje Wegi), producentami zainstalowanych aplikacji, Homebrew i App Store."))
            WegaDisclosure(isExpanded: $showsHosts) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Wega łączy się z tymi adresami albo otwiera je w przeglądarce, gdy o to poprosisz.") + " " + tr("Do tego adresy aktualizacji zapisane w zainstalowanych aplikacjach, rejestr npm i serwery App Store."))
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(AppEndpoints.shared.connectionHosts, id: \.self) { host in
                        Text(host).font(.wega(.subheadline, monospaced: true))
                    }
                }
                .textSelection(.enabled)
                .padding(.top, 6)
                .padding(.leading, 18)
            } label: {
                Text(tr("Pokaż stałe adresy")).font(.wega(.callout))
            }
        }
    }

    private var localData: some View {
        section(tr("Dane lokalne i raporty")) {
            paragraph(tr("Logi, ostatni wynik skanu i kopie sprzed aktualizacji (do 7 dni) zostają na tym Macu."))
            paragraph(tr("Raport błędu przejrzysz przed otwarciem poczty albo GitHuba."))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.wega(.subheadline, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.wega(.callout))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
