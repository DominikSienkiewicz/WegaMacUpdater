import SwiftUI
import MacUpdaterCore

struct InventoryCheckPresentation {
    let status: InstallationCheckStatus
    let check: InstallationCheck?

    init(app: ApplicationInfo, check: InstallationCheck?, policies: [String: UpdatePolicy], now: Date = Date()) {
        let matches = check.map { InstallationIdentity(path: $0.path) == app.installation && $0.bundleIdentifier == app.bundleIdentifier } ?? false
        self.check = matches ? check : nil
        status = self.check?.status(for: app, policies: policies, now: now) ?? .notChecked
    }

    var title: String {
        if status == .updateAvailable, check?.sources.contains(where: { $0.outcome == .failed }) == true {
            return tr("Aktualizacja; sprawdzenie niepełne")
        }
        switch status {
        case .notChecked: return tr("Brak potwierdzenia")
        case .current: return tr("Sprawdzona — aktualna")
        case .updateAvailable: return tr("Dostępna aktualizacja")
        case .failed: return tr("Sprawdzenie niepełne")
        case .noSource: return tr("Brak rozpoznanego źródła")
        case .excluded: return tr("Ukryte przez politykę")
        case .stale: return tr("Wynik nieaktualny")
        }
    }

    var needsAttention: Bool {
        status.needsAttention || check?.sources.contains(where: { $0.outcome == .failed || $0.outcome == .notChecked }) == true
    }

    var symbol: String {
        switch status {
        case .current: "checkmark.circle"
        case .updateAvailable: "arrow.down.circle"
        case .failed: "exclamationmark.triangle"
        case .excluded: "pause.circle"
        case .stale: "clock.badge.exclamationmark"
        case .notChecked, .noSource: "questionmark.circle"
        }
    }
}

struct InventoryCheckCell: View {
    let presentation: InventoryCheckPresentation
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails.toggle() } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(presentation.title, systemImage: presentation.symbol)
                    .font(.wega(.footnote))
                    .fixedSize(horizontal: false, vertical: true)
                if let check = presentation.check {
                    Text(check.checkedAt, style: .relative)
                        .font(.wega(.footnote))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(presentation.needsAttention ? Color.wegaHoney : Color.secondary)
        .help(tr("Źródła i czas ostatniego sprawdzenia"))
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 10) {
                Text(presentation.title).font(.headline)
                if let check = presentation.check {
                    Text(trf("Ostatnia próba: %@", check.checkedAt.formatted(date: .abbreviated, time: .shortened)))
                    Text(trf("Ostatnie pełne sprawdzenie: %@", check.lastSuccessfulCheck?.formatted(date: .abbreviated, time: .shortened) ?? "—"))
                    ForEach(Array(check.sources.enumerated()), id: \.offset) { _, source in
                        Text("\(tr(source.source)): \(sourceLabel(source.outcome))")
                    }
                    Text((check.path.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).textSelection(.enabled)
                }
                Text(tr("Status pochodzi ze sprawdzania aktualizacji. Odświeżenie spisu tylko odczytuje zainstalowane aplikacje."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 350, alignment: .leading)
        }
    }

    private func sourceLabel(_ outcome: InstallationSourceCheck.Outcome) -> String {
        switch outcome {
        case .current: tr("aktualna")
        case .outdated: tr("dostępna aktualizacja")
        case .failed: tr("źródło nie odpowiedziało poprawnie")
        case .notChecked: tr("brak wyniku dla tej instalacji")
        }
    }
}
