import SwiftUI
import MacUpdaterCore

struct InventoryCheckPresentation {
    let app: ApplicationInfo
    let status: InstallationCheckStatus
    let check: InstallationCheck?
    var serviceVendor: ServiceVendorUpdateProfile? { ServiceVendorUpdateProfile.profile(for: app) }
    var vendorAppURL: URL? { serviceVendor != nil && app.path.isFileURL ? app.path : nil }

    init(app: ApplicationInfo, check: InstallationCheck?, policies: [String: UpdatePolicy], now: Date = Date()) {
        self.app = app
        let matches = check.map { InstallationIdentity(path: $0.path) == app.installation && $0.bundleIdentifier == app.bundleIdentifier } ?? false
        self.check = matches ? check : nil
        status = self.check?.status(for: app, policies: policies, now: now) ?? .notChecked
    }

    var title: String {
        if status == .updateAvailable, check?.sources.contains(where: { $0.outcome == .failed }) == true {
            return tr("Aktualizacja; sprawdzenie niepełne")
        }
        if status == .notChecked, check?.unconfirmedCaskToken != nil {
            return tr("Powiązanie z Homebrew niepotwierdzone")
        }
        if serviceVendor != nil, status == .notChecked || status == .noSource {
            return tr("Aktualizator producenta — brak potwierdzenia")
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
                    if let token = check.unconfirmedCaskToken {
                        Text(trf("Możliwe źródło: Homebrew (%@)", token))
                        Text(tr("Brak jednoznacznego potwierdzenia tej instalacji. Wynik casku nie potwierdza aktualności tej kopii."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text((check.path.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).textSelection(.enabled)
                }
                if let profile = presentation.serviceVendor {
                    Divider()
                    Text(profile.name).font(.headline)
                    if let product = BitdefenderSupport.status(for: presentation.app) {
                        Text(trf("Wersja produktu: %@", product.installedProductVersion ?? "—"))
                        Text(trf("Build produktu: %@", product.installedProductBuild ?? "—"))
                        Text(tr("Aktualność produktu: niepotwierdzona")).font(.caption)
                        Text(tr("Aktualność sygnatur: niepotwierdzona")).font(.caption)
                    }
                    ServiceVendorUpdateControls(profile: profile, appURL: presentation.vendorAppURL)
                }
                if MicrosoftAutoUpdateSupport.applicationID(for: presentation.app) != nil {
                    Divider()
                    MicrosoftAutoUpdateControls(app: presentation.app,
                        evidence: presentation.status == .stale ? nil : presentation.check?.microsoftAutoUpdate)
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
