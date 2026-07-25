import MacUpdaterCore
import SwiftUI

/// Central audit and revocation surface for every unattended-update consent (BG-05).
/// The rows come from the durable consent ledger, never from the current outdated list.
struct BackgroundUpdateConsentSettingsCard: View {
    @EnvironmentObject private var localization: LocalizationManager
    @ObservedObject private var store = BackgroundUpdateOptInStore.shared
    @State private var qualifications: [String: BackgroundUpdateConsentQualification] = [:]

    private let brewService = BrewService()

    private var tokensKey: String {
        store.consents.map(\.token).joined(separator: "\u{1f}")
    }

    var body: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                header
                if store.consents.isEmpty {
                    emptyState
                } else {
                    ForEach(store.consents) { consent in
                        consentRow(consent)
                        if consent.id != store.consents.last?.id {
                            Divider().opacity(0.4).padding(.leading, 42)
                        }
                    }
                    runtimeNote
                }
            }
        }
        .task(id: tokensKey) {
            await refreshQualifications()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.2.circlepath")
                .foregroundStyle(Color.wegaHoney)
            Text(tr("Zgody na aktualizacje w tle"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !store.consents.isEmpty {
                Text("\(store.consents.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private var emptyState: some View {
        Text(
            tr("Brak zgód. Możesz je nadać z menu ⋯ przy chronionym casku na liście aktualizacji.")
        )
        .font(.system(size: 12))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func consentRow(_ consent: BackgroundUpdateConsent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(consent.token)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    WegaBadge(
                        label: qualificationLabel(qualifications[consent.token]),
                        variant: qualificationVariant(qualifications[consent.token])
                    )
                }
                Text(trf("Zgoda udzielona: %@", formatted(consent.grantedAt)))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(qualificationMessage(qualifications[consent.token]))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                store.setOptedIn(false, token: consent.token)
            } label: {
                Label(tr("Cofnij zgodę"), systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(tr("Cofnij zgodę"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var runtimeNote: some View {
        Text(
            tr(
                "Przed każdą aktualizacją Wega ponownie sprawdza, czy aplikacja nie działa, nie jest zignorowana lub przypięta oraz czy można utworzyć snapshot."
            )
        )
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    private func qualificationLabel(
        _ qualification: BackgroundUpdateConsentQualification?
    ) -> String {
        switch qualification {
        case .eligible:
            return tr("Stałe warunki spełnione")
        case .ineligible:
            return tr("Stałe warunki niespełnione")
        case .metadataUnavailable:
            return tr("Nie można ocenić")
        case nil:
            return tr("Sprawdzam…")
        }
    }

    private func qualificationVariant(
        _ qualification: BackgroundUpdateConsentQualification?
    ) -> WegaBadgeVariant {
        switch qualification {
        case .eligible:
            return .success
        case .metadataUnavailable, nil:
            return .info
        case .ineligible:
            return .manual
        }
    }

    private func qualificationMessage(
        _ qualification: BackgroundUpdateConsentQualification?
    ) -> String {
        switch qualification {
        case .eligible:
            return tr(
                "Instaluje aplikację bez uprzywilejowanych hooków, a pobranie ma sumę SHA-256.")
        case .ineligible(let reason):
            switch reason {
            case .noArtifacts:
                return tr(
                    "Homebrew nie opisuje artefaktów tego casku, więc nie można potwierdzić bezpiecznej aktualizacji."
                )
            case .noAppBundle:
                return tr(
                    "Cask nie instaluje aplikacji .app, więc nie można utworzyć snapshotu ani sprawdzić wyniku."
                )
            case .privilegedArtifact:
                return tr(
                    "Cask zawiera uprzywilejowany lub nieznany artefakt, który może wymagać nadzoru."
                )
            case .noChecksum:
                return tr(
                    "Pobranie nie ma konkretnej sumy SHA-256, więc Homebrew nie zweryfikuje pliku.")
            }
        case .metadataUnavailable:
            return tr(
                "Nie można teraz odczytać metadanych Homebrew. Zgoda pozostaje zapisana i można ją cofnąć."
            )
        case nil:
            return tr("Sprawdzam metadane Homebrew…")
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale =
            localization.language == .pl
            ? Locale(identifier: "pl_PL")
            : Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func refreshQualifications() async {
        let tokens = store.consents.map(\.token)
        guard !tokens.isEmpty else {
            qualifications = [:]
            return
        }

        do {
            async let profileRequest = brewService.caskArtifactProfiles(tokens: tokens)
            async let downloadRequest = brewService.caskDownloadInfo(tokens: tokens)
            let (profiles, downloads) = try await (profileRequest, downloadRequest)
            guard !Task.isCancelled else { return }
            let profilesByToken = Dictionary(
                profiles.map { ($0.token, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let downloadsByToken = Dictionary(
                downloads.map { ($0.token, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            qualifications = Dictionary(
                uniqueKeysWithValues: tokens.map { token in
                    (
                        token,
                        BackgroundUpdateConsentQualification.evaluate(
                            profile: profilesByToken[token],
                            download: downloadsByToken[token]
                        )
                    )
                })
        } catch {
            guard !Task.isCancelled else { return }
            qualifications = Dictionary(
                uniqueKeysWithValues: tokens.map {
                    ($0, BackgroundUpdateConsentQualification.metadataUnavailable)
                })
            WegaLog.warning(
                .homebrew,
                "Zgody aktualizacji w tle — nie udało się odczytać metadanych: \(error.localizedDescription)"
            )
        }
    }
}
