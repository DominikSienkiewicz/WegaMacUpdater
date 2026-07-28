import MacUpdaterCore
import SwiftUI

/// LT-02 — the switch for the post-update launch smoke test.
///
/// On by default: it is the only gate that catches a build which crashes on startup, and a
/// crash on startup is how an update most often actually fails. The switch exists because the
/// check has a cost the other gates do not — it really starts the app — and an app that takes
/// badly to being started and closed unattended needs a way out that is not "turn off
/// updates".
struct LaunchSmokeTestSettingsCard: View {
    @AppStorage(LaunchSmokeTestConfiguration.enabledKey)
    private var isEnabled = LaunchSmokeTestConfiguration.enabledByDefault

    var body: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "stethoscope", title: tr("Test startu po aktualizacji"),
                               titleTinted: true)

                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Kontrola Gatekeepera i wydawcy mówi, czym plik jest — nie mówi, czy da się go uruchomić. Po tych kontrolach Wega startuje zaktualizowaną aplikację ukrytą, w tle, i sprawdza, czy przeżyje pięć sekund. Jeśli padnie od razu, poprzednia wersja wraca ze snapshotu."))
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: $isEnabled) {
                        Text(tr("Sprawdzaj, czy zaktualizowana aplikacja się uruchamia")).font(.wega(.callout))
                    }
                    .toggleStyle(.switch)

                    Text(tr("Aplikacja, którą masz właśnie otwartą, jest pomijana — Wega nie zamknie jej, żeby zrobić sobie miejsce. Wyłącz test, jeśli któraś z aktualizowanych aplikacji źle znosi start i natychmiastowe zamknięcie."))
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
        }
    }
}
