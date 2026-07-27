import SwiftUI
import AppKit
import MacUpdaterCore

struct InfoView: View {
    var onWegaState: ((WegaState) -> Void)?

    @EnvironmentObject private var localization: LocalizationManager
    @EnvironmentObject private var policies: UpdatePolicyStore
    @StateObject private var operations = InfoOperationsController()
    @StateObject private var selfUpdateController = SelfUpdateController()
    @StateObject private var touchIDController = TouchIDSetupController()
    // OBS-02 — the diagnostics card is where a user already goes to answer "what does Wega
    // see?", so it is also where they export that answer.
    @StateObject var diagnosticsExport = DiagnosticsExportController()
    // SEC-08: opcjonalny token GitHub (Keychain).
    @State private var githubTokenInput: String = ""

    private var diagnostics: DiagnosticsResult? { operations.diagnostics }
    private var catalogRefreshing: Bool { operations.catalogRefreshing }
    private var catalogOutcome: CatalogRefresher.Outcome? { operations.catalogOutcome }
    private var helperStatus: PrivilegedHelperClient.Status { operations.helperStatus }
    private var helperBusy: Bool { operations.helperBusy }
    private var helperError: String? { operations.helperError }
    private var githubTokenStored: Bool { operations.githubTokenStored }
    private var githubTokenStatus: String? { operations.githubTokenStatus }
    private var selfUpdate: WegaSelfUpdateChecker.Result? { selfUpdateController.result }
    private var selfUpdateState: SelfUpdateController.State { selfUpdateController.state }
    private var checkingSelfUpdate: Bool { selfUpdateController.isChecking }
    private var downloadingUpdate: Bool { selfUpdateController.isDownloading }
    private var touchIDState: TouchIDSudoConfigurator.State { touchIDController.touchIDState }
    private var enablingTouchID: Bool { touchIDController.isEnabling }
    private var touchIDError: String? { touchIDController.errorMessage }
    private var touchIDPermissionDenied: Bool { touchIDController.wasPermissionDenied }
}

// Body, cards and actions live in an extension so the `InfoView` type body stays
// within SwiftLint's type_body_length budget (same file → private members still
// reachable).
extension InfoView {
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                unverifiedOverlayCard
                appCard
                languageCard
                ScanDirectoriesSettingsCard()
                ResourceGateSettingsCard()
                LaunchAtLoginSettingsCard()
                BackgroundUpdateConsentSettingsCard()
                CrashReportingSettingsCard()
                policiesCard
                diagnosticsCard
                catalogCard
                githubTokenCard
                touchIDCard
                privilegedHelperCard
                licensesCard
                environmentCard
            }
            .padding(16)
        }
        .onAppear {
            onWegaState?(WegaState(pose: .idle, line: tr("Oto co o sobie wiem.")))
            if diagnostics == nil {
                Task { await loadDiagnostics() }
            }
            // Auto-check for a Wega update the first time this card appears; the ETag-conditional
            // request makes repeat visits cheap (a 304 doesn't count against GitHub's rate limit).
            // Gated on `.idle` specifically — not "no result yet" — so a reappearance never
            // re-triggers a check that would clobber `.installedPendingRestart` (only a user
            // click may leave that state; see `SelfUpdateController.State`).
            if case .idle = selfUpdateState {
                Task { await checkSelfUpdate() }
            }
            touchIDController.refresh()
            operations.refreshPersistentState()
        }
    }

    // MARK: - Language

    private var languageCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "globe", title: tr("Język interfejsu"))

                Picker("", selection: $localization.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text("\(lang.flag)  \(lang.displayName)").tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Ignored / pinned updates

    private var policiesCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "hand.raised", title: tr("Ignorowane i przypięte")) {
                    if !policies.isEmpty {
                        Text("\(policies.sortedEntries.count)")
                            .font(.wega(.callout, monospaced: true))
                            .foregroundStyle(.tertiary)
                    }
                }

                if policies.isEmpty {
                    Text(tr("Brak reguł. Kliknij aktualizację prawym przyciskiem, aby ją zignorować lub przypiąć wersję."))
                        .font(.wega(.callout))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    ForEach(policies.sortedEntries) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: policyIcon(entry.policy))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.displayName).font(.wega(.body, weight: .medium))
                                Text(policyDescription(entry.policy))
                                    .font(.wega(.subheadline))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button { policies.remove(key: entry.key) } label: {
                                Image(systemName: "trash").font(.wega(.callout))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(tr("Usuń regułę"))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        if entry.id != policies.sortedEntries.last?.id {
                            Divider().opacity(0.4).padding(.leading, 42)
                        }
                    }
                }
            }
        }
    }

    private func policyIcon(_ policy: UpdatePolicy) -> String {
        switch policy {
        case .ignored: return "bell.slash"
        case .pinned:  return "pin"
        case .skipped: return "forward.end"
        }
    }

    private func policyDescription(_ policy: UpdatePolicy) -> String {
        switch policy {
        case .ignored:              return tr("Ignorowane")
        case .pinned(let version):  return trf("Przypięte do %@", version)
        case .skipped(let version): return trf("Pominięta wersja %@", version)
        }
    }

    // MARK: - Touch ID for sudo

    @ViewBuilder
    private var touchIDCard: some View {
        if touchIDState != .notSupported {
            WegaCard {
                VStack(alignment: .leading, spacing: 0) {
                    WegaCardHeader(icon: "touchid", title: tr("Touch ID dla Homebrew")) {
                        statusBadge
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(touchIDDescription)
                            .font(.wega(.callout))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // UX-01: jawne ujawnienie zakresu zmiany.
                        Text(tr("Działa dla całego sudo w systemie, nie tylko dla Wegi."))
                            .font(.wega(.footnote))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let err = touchIDError {
                            Text(err)
                                .font(.wega(.subheadline))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if touchIDPermissionDenied {
                            manualEnableFallback
                        } else if touchIDState == .available {
                            Button {
                                Task { await enableTouchID() }
                            } label: {
                                if enablingTouchID {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label(tr("Włącz Touch ID dla sudo"), systemImage: "touchid")
                                }
                            }
                            .disabled(enablingTouchID)
                            .controlSize(.small)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    // MARK: - GitHub token (SEC-08)

    @ViewBuilder
    private var githubTokenCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "key.horizontal", title: tr("Token GitHub (opcjonalny)")) {
                    if githubTokenStored { WegaBadge(label: tr("Zapisany"), variant: .info) }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Podnosi limit GitHub z 60 do 5000 zapytań/h i włącza zwolnienie 304. Trzymany w Keychain."))
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        SecureField("ghp_…", text: $githubTokenInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.wega(.callout, monospaced: true))
                        Button(tr("Zapisz token")) {
                            operations.saveGitHubToken(githubTokenInput)
                            githubTokenInput = ""
                        }
                        .controlSize(.small)
                        .disabled(githubTokenInput.trimmingCharacters(in: .whitespaces).isEmpty)

                        if githubTokenStored {
                            Button(role: .destructive) {
                                operations.clearGitHubToken()
                            } label: { Text(tr("Wyczyść")) }
                                .controlSize(.small)
                        }
                    }

                    if let status = githubTokenStatus {
                        Text(status).font(.wega(.subheadline)).foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: - Privileged helper (FEAT-01)

    @ViewBuilder
    private var privilegedHelperCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "lock.shield", title: tr("Komponent uprzywilejowany")) {
                    helperStatusBadge
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Pozwala instalować zweryfikowane aktualizacje i konfigurować Touch ID bez wpisywania hasła — przez podpisany helper (XPC) z białą listą operacji."))
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let err = helperError {
                        Text(err)
                            .font(.wega(.subheadline))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    helperActions
                }
                .padding(14)
            }
        }
    }

    private var helperStatusBadge: some View {
        Group {
            switch helperStatus {
            case .enabled:          WegaBadge(label: tr("Aktywny"), variant: .info)
            case .requiresApproval: WegaBadge(label: tr("Wymaga zgody"), variant: .manual)
            case .notRegistered:    WegaBadge(label: tr("Niezarejestrowany"), variant: .manual)
            case .notFound:         WegaBadge(label: tr("Nie znaleziono"), variant: .manual)
            case .unknown:          EmptyView()
            }
        }
    }

    @ViewBuilder
    private var helperActions: some View {
        HStack(spacing: 8) {
            switch helperStatus {
            case .enabled:
                Button(role: .destructive) {
                    Task { await removeHelper() }
                } label: { Label(tr("Usuń komponent"), systemImage: "trash") }
                    .controlSize(.small)
                    .disabled(helperBusy)
            case .requiresApproval:
                Button {
                    operations.openLoginItemsSettings()
                } label: { Label(tr("Otwórz Ustawienia → Elementy logowania"), systemImage: "gearshape") }
                    .controlSize(.small)
                Button(tr("Sprawdź ponownie")) { operations.refreshHelperStatus() }
                    .controlSize(.small)
            default:
                Button {
                    Task { await installHelper() }
                } label: {
                    if helperBusy { ProgressView().controlSize(.small) }
                    else { Label(tr("Zainstaluj komponent"), systemImage: "lock.shield") }
                }
                .controlSize(.small)
                .disabled(helperBusy)
            }
            Spacer()
        }
    }

    private func installHelper() async {
        await operations.installHelper { state in
            onWegaState?(state)
        }
    }

    private func removeHelper() async {
        await operations.removeHelper()
    }

    private var statusBadge: some View {
        Group {
            switch touchIDState {
            case .enabled:
                WegaBadge(label: tr("Aktywne"), variant: .info)
            case .available:
                WegaBadge(label: tr("Dostępne"), variant: .manual)
            case .notSupported:
                EmptyView()
            }
        }
    }

    private var touchIDDescription: String {
        switch touchIDState {
        case .enabled:
            return tr("Sudo używa Touch ID. Aktualizacje casków z sudo (Zoom, sterowniki, launchd) potwierdzisz odciskiem zamiast hasła.")
        case .available:
            return tr("Po włączeniu, brew nie zapyta o hasło w okienku — pojawi się natywny sheet Touch ID. Wymaga jednorazowo uprawnień administratora do zapisu /etc/pam.d/sudo_local.")
        case .notSupported:
            return ""
        }
    }

    /// Manual fallback shown when the signed privileged helper is unavailable.
    /// Renders the exact one-liner the user should paste into Terminal,
    /// plus buttons to copy it and to open Terminal.app pre-armed with it.
    @ViewBuilder
    private var manualEnableFallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Bezpieczny zapis PAM wymaga podpisanego helpera. Jeśli jest niedostępny, uruchom poniższą transakcyjną komendę w Terminalu — wystarczy raz:"))
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(TouchIDSudoConfigurator.manualEnableTerminalCommand)
                .font(.wega(.subheadline, monospaced: true))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.wegaRecessedSurface, in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        TouchIDSudoConfigurator.manualEnableTerminalCommand,
                        forType: .string
                    )
                } label: {
                    Label(tr("Skopiuj komendę"), systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button {
                    openInTerminal(TouchIDSudoConfigurator.manualEnableTerminalCommand)
                } label: {
                    Label(tr("Otwórz w Terminalu"), systemImage: "terminal")
                }
                .controlSize(.small)

                Spacer()

                Button(tr("Sprawdź ponownie")) {
                    touchIDController.refresh()
                }
                .controlSize(.small)
            }
        }
    }

    private func openInTerminal(_: String) {
        touchIDController.openManualFallback()
    }

    // MARK: - Self-update (Wega dogfooding its own GitHub releases)

    @ViewBuilder
    private var selfUpdateRow: some View {
        HStack(spacing: 10) {
            // `selfUpdate` (== `selfUpdateController.result`) is nil for `.idle`, `.checking` and
            // `.installedPendingRestart` alike, so that terminal state needs its own case here —
            // otherwise it could never render (it would fall into the bare check button below).
            switch selfUpdateState {
            case .installedPendingRestart(let version):
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Color.wegaHoney)
                Text(trf("Zainstalowano wersję %@", version))
                    .font(.wega(.callout, weight: .semibold))
                Spacer()
                Button(tr("Uruchom Wegę ponownie")) { selfUpdateController.restart() }
                    .disabled(!selfUpdateController.canRestart)
            case .idle, .checking, .result, .downloading:
                switch selfUpdate {
                case .updateAvailable(let version, let assets, let releaseURL, let notes):
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.wegaHoney)
                    Text(trf("Dostępna wersja %@", version)).font(.wega(.callout, weight: .semibold))
                    // FEAT-06: doradczy badge, jeśli notatki wydania wyglądają na poprawkę bezpieczeństwa.
                    if ReleaseNotesTriage.heuristic(notes).isLikelySecurityFix {
                        Label(tr("możliwa poprawka bezpieczeństwa"), systemImage: "shield.lefthalf.filled")
                            .font(.wega(.footnote, weight: .medium))
                            .foregroundStyle(Color.wegaDanger)
                    }
                    Spacer()
                    Link(tr("Zobacz wydanie"), destination: releaseURL).font(.wega(.callout))
                    // UX-06 — the single decision site for install-vs-open in the whole app: the
                    // planner is consulted here, once, from the published assets and real helper
                    // capability. No plan, no button — never force-unwrapped.
                    if let action = SelfUpdatePlanner.action(
                        helperEnabled: PrivilegedHelperClient.shared.isEnabled,
                        assets: assets
                    ) {
                        Button {
                            Task { await applySelfUpdate(action, version: version) }
                        } label: {
                            if downloadingUpdate { ProgressView().controlSize(.small) }
                            // UX-06 — the label describes the operation that will actually run: a
                            // headless install of a verified .pkg, or the download the user
                            // finishes by hand. "Install" no longer covers both.
                            else { Text(SelfUpdatePresentation.actionLabel(action)) }
                        }
                        .disabled(downloadingUpdate)
                    }
                case .upToDate:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(tr("Masz najnowszą wersję Wegi")).font(.wega(.callout)).foregroundStyle(.secondary)
                    Spacer()
                    selfUpdateCheckButton
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(tr("Nie udało się sprawdzić aktualizacji")).font(.wega(.callout)).foregroundStyle(.secondary)
                    Spacer()
                    selfUpdateCheckButton
                case nil:
                    Spacer()
                    selfUpdateCheckButton
                }
            }
        }
    }

    /// The cumulative "what's new" between the installed version and the newest one. One
    /// collapsible entry per release; markup was stripped in Core before it got here.
    @ViewBuilder
    private var selfUpdateNotes: some View {
        switch selfUpdateController.history {
        case .history(let history) where !history.notes.isEmpty:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(history.notes) { note in
                    DisclosureGroup {
                        Text(note.body.isEmpty ? tr("Brak opublikowanych notatek") : note.body)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: {
                        HStack(spacing: 6) {
                            Text(note.version).font(.system(size: 12, weight: .medium))
                            if let published = note.publishedAt {
                                Text(published, style: .date)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if history.omitted > 0 {
                    Text(trf("…i %@ wcześniejszych wydań", String(history.omitted)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        case .unavailable:
            Text(tr("Nie udało się pobrać notatek wydania"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .history, .none:
            EmptyView()
        }
    }

    private var selfUpdateCheckButton: some View {
        Button {
            Task { await checkSelfUpdate() }
        } label: {
            if checkingSelfUpdate { ProgressView().controlSize(.small) }
            else { Text(tr("Sprawdź aktualizacje Wegi")) }
        }
        .disabled(checkingSelfUpdate)
    }

    private func checkSelfUpdate() async {
        await selfUpdateController.check()
    }

    /// Download the release asset to a temp file and hand it to the system (Installer for
    /// `.pkg`, DiskImageMounter for `.dmg`). On any failure, fall back to opening the asset
    /// URL in the browser so the user can still grab it.
    private func applySelfUpdate(_ action: SelfUpdateAction, version: String) async {
        // Persistent audit moved with the operation to SelfUpdateController:
        // WegaLog.error(.app, "Self-update odrzucony przez weryfikację podpisu")
        // WegaLog.error(.helper, "Instalacja przez helper nie powiodła się")
        await selfUpdateController.apply(action, version: version) { state in
            onWegaState?(state)
        }
    }

    private func enableTouchID() async {
        await touchIDController.enable { state in
            onWegaState?(state)
        }
    }

    // MARK: - Unverified endpoints overlay (SEC-08)

    /// SEC-08 — an endpoints overlay applied without a valid signature reshapes every URI the app
    /// talks to. Its use is logged, but a log line is not visible to the user, so its presence is
    /// surfaced here as a first-class warning. Renders nothing when no unverified overlay is active.
    @ViewBuilder
    private var unverifiedOverlayCard: some View {
        if AppEndpoints.overlayStatus.isUnverifiedOverlayActive {
            WegaCard {
                VStack(alignment: .leading, spacing: 0) {
                    WegaCardHeader(icon: "exclamationmark.shield.fill", tint: Color.wegaDanger,
                                   title: tr("Nieweryfikowana konfiguracja endpointów")) {
                        WegaBadge(label: tr("Niezweryfikowany"), variant: .danger)
                    }

                    Text(tr("W Application Support znaleziono plik endpoints.json bez ważnego podpisu. Wega zastosowała go zgodnie z polityką, ale nie mogła zweryfikować jego pochodzenia — sprawdź, czy to Twoja zmiana."))
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
        }
    }

    // MARK: - App card

    private var appCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    WegaIcon(size: 56, radius: 14)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WegaMacUpdater")
                            .font(.wega(.title, weight: .bold))
                        HStack(spacing: 16) {
                            LabeledValue(label: tr("Wersja"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppMetadata.version)
                            LabeledValue(label: tr("Build"), value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                        }
                    }
                    Spacer()
                }
                .padding(14)

                Divider().opacity(0.5)

                selfUpdateRow
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                selfUpdateNotes
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                Divider().opacity(0.5)

                HStack(spacing: 8) {
                    Text(tr("Architected & Developed by"))
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                    Link("Dominik Sienkiewicz", destination: AppEndpoints.shared.authorLinkedInURL)
                        .font(.wega(.callout, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 2)

                Text("Principal AI Engineer · Full Stack Architect")
                    .font(.wega(.subheadline))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                Divider().opacity(0.5)

                HStack(spacing: 16) {
                    Link("GitHub", destination: AppEndpoints.shared.projectRepositoryURL)
                        .font(.wega(.body))
                    Link(tr("Zgłoś błąd"), destination: AppEndpoints.shared.projectIssuesURL)
                        .font(.wega(.body))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Diagnostics card

    private var diagnosticsCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "stethoscope", title: tr("Diagnostyka systemu"))

                if let d = diagnostics {
                    VStack(alignment: .leading, spacing: 0) {
                        DiagRow(label: "Homebrew", required: true, value: d.brewVersion)
                        Divider().opacity(0.3).padding(.leading, 30)
                        DiagRow(label: "mas-cli", required: false, value: d.masVersion)
                        Divider().opacity(0.3).padding(.leading, 30)
                        // REL-05 — the preflight, so a missing "App Management" grant is
                        // visible before the first upgrade rather than after it fails.
                        DiagRow(label: tr("Zarządzanie aplikacjami"),
                                required: true,
                                value: Self.appManagementStatusText(d.appManagement),
                                healthy: d.appManagement != .denied)
                        if d.appManagement == .denied {
                            Button(tr("Otwórz ustawienia prywatności")) {
                                NSWorkspace.shared.open(AppManagementSettings.paneURL)
                            }
                            .buttonStyle(.link)
                            .font(.wega(.subheadline))
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    .padding(14)
                }

                Divider().opacity(0.5)
                diagnosticsExportRow
            }
        }
    }

    /// OBS-02 — one action that packages everything a bug report needs, so filing one stops
    /// meaning "copy the log, find the version, remember which managers you have".
    private var diagnosticsExportRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    Task { await diagnosticsExport.export() }
                } label: {
                    Label(tr("Eksportuj diagnostykę"), systemImage: "shippingbox")
                }
                .disabled(diagnosticsExport.isExporting)

                if diagnosticsExport.isExporting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if diagnosticsExport.lastExportURL != nil {
                    Button(tr("Pokaż w Finderze")) { diagnosticsExport.revealLastExport() }
                        .buttonStyle(.link)
                        .font(.wega(.subheadline))
                }
            }

            Text(tr("Zapisuje paczkę zip z oboma plikami logów, wersjami, wykrytymi menedżerami, statusem harmonogramu i historią aktualizacji. Ścieżki, tokeny i nazwy użytkownika są zastąpione znacznikami; nic nie jest nigdzie wysyłane."))
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = diagnosticsExport.lastError {
                Text(error)
                    .font(.wega(.subheadline))
                    .foregroundStyle(Color.wegaDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    // MARK: - App catalog

    /// Lets the user pull the latest `AppCatalog` overlay on demand (the app also
    /// refreshes it on launch). The catalog loads once per process, so a fetched
    /// update takes effect on the next launch — the status text says so.
    private var catalogCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "books.vertical", title: tr("Katalog aplikacji"))

                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Wega pobiera mapowania aplikacji (repozytoria GitHub, kody IDE JetBrains, feedy Sparkle) z sieci, więc nowe aplikacje są obsługiwane bez aktualizacji Wegi. Zmiany zastosują się po ponownym uruchomieniu."))
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button {
                            Task { await refreshCatalog() }
                        } label: {
                            if catalogRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(tr("Odśwież katalog"), systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(catalogRefreshing)
                        .controlSize(.small)

                        if let outcome = catalogOutcome, !catalogRefreshing {
                            catalogStatus(outcome)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private func catalogStatus(_ outcome: CatalogRefresher.Outcome) -> some View {
        switch outcome {
        case .updated:
            catalogStatusLabel(tr("Zaktualizowano — zrestartuj Wegę, aby zastosować."),
                               icon: "checkmark.circle.fill", color: .green)
        case .notModified:
            catalogStatusLabel(tr("Katalog jest aktualny."),
                               icon: "checkmark.circle", color: .secondary)
        case .invalid:
            catalogStatusLabel(tr("Pobrany katalog był nieprawidłowy — pominięto."),
                               icon: "exclamationmark.triangle.fill", color: .orange)
        case .signatureMismatch:
            // F5(d) — the body is a catalog, but its signature does not match it. We cannot
            // tell tampering from a CDN that paired a fresh JSON with a cached `.sig`, so the
            // wording describes what happened, not who to blame, and the old catalog stays.
            catalogStatusLabel(tr("Podpis nie pasuje do katalogu — zachowano poprzedni."),
                               icon: "exclamationmark.shield.fill", color: .orange)
        case .replayRejected:
            // SEC-07 — correctly signed, but older than what this Mac already trusts. That is
            // what a rollback attack looks like from here, and also what a mis-published
            // catalog looks like; the wording states the fact and keeps the newer catalog.
            catalogStatusLabel(tr("Serwer podał starszy katalog niż zainstalowany — odrzucono."),
                               icon: "exclamationmark.shield.fill", color: .orange)
        case .unsupportedSchema:
            catalogStatusLabel(tr("Katalog w nowszym formacie — zaktualizuj Wegę."),
                               icon: "arrow.up.circle.fill", color: .orange)
        case .failed:
            catalogStatusLabel(tr("Nie udało się pobrać katalogu — sprawdź połączenie."),
                               icon: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    private func catalogStatusLabel(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.wega(.subheadline))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshCatalog() async {
        await operations.refreshCatalog()
    }

    // MARK: - Licenses card

    private var licensesCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "doc.text", title: tr("Zewnętrzne narzędzia"))

                VStack(alignment: .leading, spacing: 0) {
                    LicenseRow(name: "Homebrew", license: "BSD 2-Clause", url: AppEndpoints.shared.homebrewWebsiteURL)
                    Divider().opacity(0.3)
                    LicenseRow(name: "mas-cli", license: "MIT", url: AppEndpoints.shared.masRepositoryURL)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Environment card

    private var environmentCard: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "cpu", title: tr("Środowisko"))

                HStack(alignment: .top, spacing: 32) {
                    LabeledValue(
                        label: "macOS",
                        value: ProcessInfo.processInfo.operatingSystemVersionString
                    )
                    LabeledValue(
                        label: "CPU",
                        value: "\(ProcessInfo.processInfo.processorCount) rdzenie · \(Self.cpuArch())"
                    )
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Helpers

    /// REL-05 — the preflight is *indicative*: `unknown` says so instead of implying a
    /// clean bill of health nobody checked.
    private static func appManagementStatusText(_ permission: AppManagementPermission) -> String {
        switch permission {
        case .granted: return tr("przyznane")
        case .denied:  return tr("odmowa")
        case .unknown: return tr("nieustalone")
        }
    }

    private static func cpuArch() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &info.machine) { rawBytes -> String in
            guard let base = rawBytes.baseAddress else { return "unknown" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    private func loadDiagnostics() async {
        await operations.loadDiagnostics()
    }
}

// MARK: - Sub-views

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.wega(.footnote, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(value)
                .font(.wega(.callout, monospaced: true))
        }
    }
}

private struct DiagRow: View {
    let label: String
    var required: Bool = false
    var value: String? = nil
    var active: Bool? = nil
    /// Overrides the dot's colour for rows whose *value* carries the verdict — a present
    /// value normally means "found", but "odmowa" is a present value that is not healthy.
    var healthy: Bool? = nil

    private var statusColor: Color {
        if let healthy { return healthy ? .wegaSuccess : Color.wegaDanger }
        if value != nil { return .wegaSuccess }
        if active == true { return .wegaSuccess }
        if required { return Color.wegaDanger }
        return .secondary
    }

    private var statusText: String {
        if let v = value { return v }
        if let a = active { return a ? tr("aktywny") : tr("nieaktywny") }
        return required ? tr("nie znaleziono") : tr("niedostępny")
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(label).font(.wega(.callout))
            Spacer()
            Text(statusText)
                .font(.wega(.subheadline, monospaced: true))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

private struct LicenseRow: View {
    let name: String
    let license: String
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.wega(.callout, weight: .medium))
            Text(license)
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
            Spacer()
            Link("↗", destination: url)
                .font(.wega(.callout))
        }
        .padding(.vertical, 5)
    }
}
