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
    private let gatherEnvironment: @Sendable () async -> [ReportField]
    private let builder = BugReportBuilder()

    /// The in-flight gather, if any. `@MainActor` isolation is reentrant across suspension
    /// points, so a second overlapping `loadEnvironment()` call can observe `environment ==
    /// nil` before the first call has assigned it — without this handle it would start a
    /// second, redundant gather. Storing it *before* awaiting it is what makes it visible
    /// to that reentrant caller in time to join instead of duplicating the work.
    private var environmentGatherTask: Task<[ReportField], Never>?

    init(
        entries: [LogEntry],
        opener: URLOpening = WorkspaceURLOpener(),
        gatherEnvironment: @escaping @Sendable () async -> [ReportField] = {
            let snapshot = await DiagnosticsExportController().snapshot()
            return BugReportEnvironment.fields(from: snapshot)
        }
    ) {
        self.entries = entries
        self.opener = opener
        self.gatherEnvironment = gatherEnvironment
    }

    /// Metryczka jest dociągana asynchronicznie, więc wysyłka czeka, aż będzie komplet.
    var isReady: Bool { environment != nil }

    var emailChannel: BugReportChannel { .email(address: AppEndpoints.shared.supportEmailAddress) }
    var gitHubChannel: BugReportChannel { .gitHubIssue(endpoint: AppEndpoints.shared.projectNewIssueURL) }

    func loadEnvironment() async {
        guard environment == nil else { return }
        let task: Task<[ReportField], Never>
        if let inFlight = environmentGatherTask {
            task = inFlight
        } else {
            let newTask = Task { [gatherEnvironment] in await gatherEnvironment() }
            environmentGatherTask = newTask
            task = newTask
        }
        environment = await task.value
    }

    /// Dokładnie ten tekst, który trafi do URL-a — łącznie z przycięciem. Podgląd
    /// i wysyłka nie mogą się rozjechać, więc obie liczą to samo.
    func preview(for channel: BugReportChannel) -> BugReportBody {
        builder.body(draft, channel: channel)
    }

    func title() -> String { builder.title(draft) }

    func url(for channel: BugReportChannel) -> URL? { builder.url(draft, channel: channel) }

    func send(_ channel: BugReportChannel) {
        guard let url = url(for: channel) else {
            // Same user-facing state as "system can't open it": the window's no-handler
            // state shows the address, subject and body to copy, which is exactly what
            // someone needs when the app cannot open anything itself.
            outcome = .noHandler(channel)
            WegaLog.error(.app, "Nie udało się zbudować URL-a zgłoszenia dla kanału \(channelLabel(channel)).")
            return
        }
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

    /// Identifies the channel in a log line without ever including report content —
    /// no address, no endpoint, no title or body text.
    private func channelLabel(_ channel: BugReportChannel) -> String {
        switch channel {
        case .email:       return "email"
        case .gitHubIssue: return "GitHub"
        }
    }
}

extension BugReportController: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
