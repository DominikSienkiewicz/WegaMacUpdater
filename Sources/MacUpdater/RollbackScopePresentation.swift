import SwiftUI
import MacUpdaterCore

struct RollbackScopePresentation: Equatable {
    let title: String
    let details: String
    let migrationWarning: String

    var localizedDescription: String {
        [title, details, migrationWarning].map(tr).joined(separator: "\n\n")
    }

    static func notice(for scope: RollbackProtection.Scope) -> Self? {
        guard scope == .dockerAppBundleOnly else { return nil }
        return Self(
            title: "Cofanie obejmuje tylko Docker.app",
            details: "Wega nie kopiuje ani nie przywraca ustawień Dockera, maszyny wirtualnej, woluminów ani danych kontenerów; nie tworzy ani nie weryfikuje kopii środowiska.",
            migrationWarning: "Przywrócenie starszej aplikacji nie gwarantuje zgodności danych po migracji. Do odzyskania środowiska potrzebna jest osobna kopia danych."
        )
    }
}

struct RollbackScopeNotice: View {
    let scope: RollbackProtection.Scope
    var compact = false

    var body: some View {
        if let notice = RollbackScopePresentation.notice(for: scope) {
            VStack(alignment: .leading, spacing: 4) {
                Label(tr(notice.title), systemImage: "exclamationmark.shield")
                    .font(.wega(.footnote, weight: .medium))
                    .foregroundStyle(Color.wegaToffee)
                if !compact {
                    Text(tr(notice.details))
                        .foregroundStyle(.secondary)
                    Text(tr(notice.migrationWarning))
                        .foregroundStyle(Color.wegaToffee)
                }
            }
            .font(.wega(.footnote))
            .fixedSize(horizontal: false, vertical: true)
            .help(notice.localizedDescription)
        }
    }
}
