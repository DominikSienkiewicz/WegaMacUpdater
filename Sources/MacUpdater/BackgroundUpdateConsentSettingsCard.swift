import AppKit
import Combine
import MacUpdaterCore
import SwiftUI

/// Central audit and revocation surface for every unattended-update consent (BG-05).
/// The rows come from the durable consent ledger, never from the current outdated list.
struct BackgroundUpdateConsentSettingsCard: View {
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var localization: LocalizationManager
  @EnvironmentObject private var policies: UpdatePolicyStore
  @ObservedObject private var store = BackgroundUpdateOptInStore.shared
  @State private var qualifications: [String: BackgroundUpdateConsentQualification] = [:]
  @State private var refreshGeneration = 0

  private let metadataReader: BackgroundUpdateConsentMetadataReader

  init(metadataReader: BackgroundUpdateConsentMetadataReader = .init()) {
    self.metadataReader = metadataReader
  }

  private var tokensKey: String {
    let policyKey = policies.policiesMap.sorted { $0.key < $1.key }.map { key, policy in
      "\(key)=\(String(describing: policy))"
    }.joined(separator: "\u{1e}")
    return store.consents.map(\.token).joined(separator: "\u{1f}") + "|" + policyKey
  }

  private var refreshTaskID: BackgroundConsentRefreshTaskID {
    BackgroundConsentRefreshTaskID(
      configurationKey: tokensKey,
      lifecycleGeneration: refreshGeneration,
      isActive: scenePhase == .active
    )
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
    .task(id: refreshTaskID) {
      await runQualificationRefreshLoop()
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.didLaunchApplicationNotification
      )
    ) { _ in
      refreshGeneration &+= 1
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.didTerminateApplicationNotification
      )
    ) { _ in
      refreshGeneration &+= 1
    }
  }

  private var header: some View {
    WegaCardHeader(icon: "clock.arrow.2.circlepath", title: tr("Zgody na aktualizacje w tle")) {
      if !store.consents.isEmpty {
        Text("\(store.consents.count)")
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.tertiary)
      }
    }
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
        "Status każdego pakietu uwzględnia bieżącą aktualizację, reguły i uruchomioną aplikację. Snapshot, zasoby i bezpieczeństwo wydawcy są sprawdzane dopiero bezpośrednio przed aktualizacją."
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
      return tr("Gotowe do kontroli końcowej")
    case .ineligible:
      return tr("Stałe warunki niespełnione")
    case .blocked:
      return tr("Teraz zablokowane")
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
    case .blocked(.notCurrentlyOutdated):
      return .info
    case .blocked:
      return .manual
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
        "Pakiet oczekuje na aktualizację, aplikacja nie działa, nie ma reguły blokującej, a metadane spełniają stałe warunki."
      )
    case .blocked(let blocker):
      switch blocker {
      case .ignored:
        return tr("Aktualizacje tego pakietu są ignorowane.")
      case .pinned(let version):
        return trf("Pakiet jest przypięty do wersji %@.", version)
      case .skipped(let version):
        return trf("Wersja %@ tego pakietu jest pominięta.", version)
      case .notCurrentlyOutdated:
        return tr("Pakiet nie oczekuje teraz na aktualizację; zgoda pozostaje zapisana.")
      case .installedAppUnavailable:
        return tr(
          "Nie można rozpoznać zainstalowanej aplikacji .app wymaganej do snapshotu i kontroli wyniku."
        )
      case .running:
        return tr("Aplikacja jest teraz uruchomiona i nie może być bezpiecznie zastąpiona.")
      }
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

  private func runQualificationRefreshLoop() async {
    guard scenePhase == .active else { return }

    do {
      try await Task.sleep(for: .milliseconds(250))
      while !Task.isCancelled {
        await refreshQualifications()
        try await Task.sleep(for: .seconds(30))
      }
    } catch {
      return
    }
  }

  private func refreshQualifications() async {
    let tokens = store.consents.map(\.token)
    guard !tokens.isEmpty else {
      qualifications = [:]
      return
    }

    do {
      let metadata = try await metadataReader.read(tokens: tokens)
      try Task.checkCancellation()
      let profilesByToken = Dictionary(
        metadata.profiles.map { ($0.token, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      let downloadsByToken = Dictionary(
        metadata.downloads.map { ($0.token, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      let appPaths = CaskAppPathResolver().appPaths(from: metadata.installations)
      let runningAppPaths = Set(
        NSWorkspace.shared.runningApplications.compactMap(
          \.bundleURL?.standardizedFileURL
        )
      )
      let context = BackgroundUpdateConsentContext(
        candidateTokens: Set(metadata.outdated.casks.map(\.name)),
        resolvedAppTokens: Set(appPaths.keys),
        runningTokens: Set(
          appPaths.filter {
            runningAppPaths.contains($0.value.standardizedFileURL)
          }.keys
        ),
        policies: policies.policiesMap
      )
      qualifications = Dictionary(
        uniqueKeysWithValues: tokens.map { token in
          (
            token,
            BackgroundUpdateConsentQualification.evaluate(
              token: token,
              profile: profilesByToken[token],
              download: downloadsByToken[token],
              context: context
            )
          )
        }
      )
    } catch {
      guard !Task.isCancelled else { return }
      let unknownRuntimeContext = BackgroundUpdateConsentContext(
        candidateTokens: Set(tokens),
        resolvedAppTokens: Set(tokens),
        runningTokens: [],
        policies: policies.policiesMap
      )
      qualifications = Dictionary(
        uniqueKeysWithValues: tokens.map { token in
          (
            token,
            BackgroundUpdateConsentQualification.evaluate(
              token: token,
              profile: nil,
              download: nil,
              context: unknownRuntimeContext
            )
          )
        })
      WegaLog.warning(
        .homebrew,
        "Zgody aktualizacji w tle — nie udało się odczytać metadanych: \(error.localizedDescription)"
      )
    }
  }
}

struct BackgroundConsentRefreshTaskID: Hashable {
  let configurationKey: String
  let lifecycleGeneration: Int
  let isActive: Bool
}
