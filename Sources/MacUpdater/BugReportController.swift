import Foundation
import MacUpdaterCore
import SwiftUI

/// Model okna „Zgłoś błąd": trzyma zaznaczone wpisy i opis użytkownika, dociąga metryczkę
/// środowiska i otwiera wybrany kanał.
///
/// Metryczkę bierze z ``DiagnosticsExportController/snapshot()`` — tego samego kodu, który
/// zbiera dane do paczki diagnostycznej. Drugi zbieracz oznaczałby dwa opisy tej samej
/// maszyny, które z czasem zaczęłyby się różnić.
///
/// To wywołanie odpytuje `brew --version` i podobne z pięciosekundowym limitem, więc okno
/// otwiera się natychmiast z wpisami i polem opisu, a metryczka dopina się asynchronicznie.
@MainActor
final class BugReportController: ObservableObject {

    enum Outcome: Equatable {
        case idle
        /// Kanał otwarty — wiadomość czeka w kliencie użytkownika.
        case opened(BugReportChannel)
        /// System nie ma czym obsłużyć tego kanału. To nie błąd: okno pokazuje wtedy
        /// adres, temat i treść do skopiowania.
        case noHandler(BugReportChannel)
    }

    let entries: [LogEntry]

    @Published var userDescription: String = ""
    @Published private(set) var environment: [ReportField]?
    @Published private(set) var outcome: Outcome = .idle

    private let opener: URLOpening
    private let builder = BugReportBuilder()

    init(entries: [LogEntry], opener: URLOpening = WorkspaceURLOpener()) {
        self.entries = entries
        self.opener = opener
    }

    /// Metryczka jest dociągana asynchronicznie, więc wysyłka czeka, aż będzie komplet.
    var isReady: Bool { environment != nil }

    var emailChannel: BugReportChannel { .email(address: AppEndpoints.shared.supportEmailAddress) }
    var gitHubChannel: BugReportChannel { .gitHubIssue(endpoint: AppEndpoints.shared.projectNewIssueURL) }

    func loadEnvironment() async {
        guard environment == nil else { return }
        let snapshot = await DiagnosticsExportController().snapshot()
        environment = BugReportEnvironment.fields(from: snapshot)
    }

    /// Dokładnie ten tekst, który trafi do URL-a — łącznie z przycięciem. Podgląd
    /// i wysyłka nie mogą się rozjechać, więc obie liczą to samo.
    func preview(for channel: BugReportChannel) -> BugReportBody {
        builder.body(draft, channel: channel)
    }

    func title() -> String { builder.title(draft) }

    func url(for channel: BugReportChannel) -> URL? { builder.url(draft, channel: channel) }

    func send(_ channel: BugReportChannel) {
        guard let url = url(for: channel) else { return }
        guard opener.canOpen(url), opener.open(url) else {
            outcome = .noHandler(channel)
            return
        }
        outcome = .opened(channel)
        WegaLog.info(.app, "Utworzono zgłoszenie błędu (\(entries.count) wpisów).")
    }

    /// Wstrzykuje gotową metryczkę, żeby testy nie musiały odpytywać realnego systemu.
    func applyEnvironmentForTests(_ fields: [ReportField]) {
        environment = fields
    }

    private var draft: BugReportDraft {
        BugReportDraft(
            userDescription: userDescription,
            environment: environment ?? [],
            entries: entries
        )
    }
}

extension BugReportController: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
