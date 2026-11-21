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
    @State private var reportController: BugReportController?
    @ObservedObject private var route = SettingsRoute.shared
    /// UXP-15 — the last message of each card's action, shown under that card's buttons.
    @State private var cardHints: [SettingsCard: String] = [:]

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
    private var disablingTouchID: Bool { touchIDController.isDisabling }
    private var touchIDError: String? { touchIDController.errorMessage }
}

// Body, cards and actions live in an extension so the `InfoView` type body stays
// within SwiftLint's type_body_length budget (same file → private members still
// reachable).
extension InfoView {
    var body: some View {
        TabView(selection: $route.tab) {
            Tab(SettingsTab.general.title, systemImage: SettingsTab.general.systemImage, value: SettingsTab.general) { generalTab }
            Tab(SettingsTab.checking.title, systemImage: SettingsTab.checking.systemImage, value: SettingsTab.checking) { checkingTab }
            Tab(SettingsTab.permissions.title, systemImage: SettingsTab.permissions.systemImage, value: SettingsTab.permissions) { permissionsTab }
            Tab(SettingsTab.cleanup.title, systemImage: SettingsTab.cleanup.systemImage, value: SettingsTab.cleanup) { cleanupTab }
            Tab(SettingsTab.advanced.title, systemImage: SettingsTab.advanced.systemImage, value: SettingsTab.advanced) { advancedTab }
        }
        .onChange(of: helperStatus) { _, status in
            cardHints[.helper] = InfoOperationsController.helperHint(cardHints[.helper], after: status)
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
            Task { await touchIDController.refreshDisableOffer() }
            operations.refreshPersistentState()
        }
        .sheet(item: $reportController) { controller in
            BugReportSheet(controller: controller) { reportController = nil }
        }
    }

    // MARK: - Tabs

    private var generalTab: some View {
        page(.general) {
            appCard
            languageCard
            LaunchAtLoginSettingsCard()
            NotificationsSettingsCard()
        }
    }

    private var checkingTab: some View {
        page(.checking) {
            policiesCard
            BackgroundUpdateConsentSettingsCard()
            ScanDirectoriesSettingsCard()
            ResourceGateSettingsCard()
        }
    }

    private var permissionsTab: some View {
        page(.permissions) {
            TrustSettingsCard(appManagement: diagnostics?.appManagement, touchIDSupported: touchIDState != .notSupported)
                .id(SettingsCard.trust)
            privilegedHelperCard
            touchIDCard
        }
    }

    private var cleanupTab: some View {
        page(.cleanup) {
            CleanupProjectRootsSettingsCard()
            CleanupTCCMapSettingsCard()
        }
    }

    private var advancedTab: some View {
        page(.advanced) {
            LaunchSmokeTestSettingsCard()
            CrashReportingSettingsCard()
            catalogCard
            githubTokenCard
            diagnosticsCard
            environmentCard
            licensesCard
        }
    }

    // MARK: - Page and card hints

    /// One tab's page: the unverified-endpoints warning tops every tab, then the tab's cards.
    private func page<Content: View>(_ tab: SettingsTab, @ViewBuilder _ content: () -> Content) -> some View {
        SettingsPage(tab: tab, route: route) {
            unverifiedOverlayCard
            content()
        }
    }

    /// Sends a card's messages under its buttons, and on to Wega when the hosting window has her.
    /// Asking for a relay starts a new action on the card, so its previous message goes first.
    func relay(_ card: SettingsCard) -> @MainActor (WegaState) -> Void {
        cardHints[card] = nil
        return { state in
            cardHints[card] = state.line
            onWegaState?(state)
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
                WegaCardHeader(icon: "hand.raised", title: tr("Wstrzymane aktualizacje")) {
                    if !policies.isEmpty {
                        Text("\(policies.sortedEntries.count)")
                            .font(.wega(.callout, monospaced: true))
                            .foregroundStyle(.tertiary)
                    }
                }

                if policies.isEmpty {
                    Text(tr("Brak reguł. Na liście aktualizacji otwórz „Więcej działań” przy aplikacji."))
                        .font(.wega(.callout))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    PolicyRulesList(entries: policies.sortedEntries, onRestore: { policies.remove(key: $0.key) })
                }
            }
        }
        .id(SettingsCard.policies)
    }

    // MARK: - Touch ID for sudo

    @ViewBuilder
    private var touchIDCard: some View {
        if touchIDState != .notSupported {
            WegaCard {
                VStack(alignment: .leading, spacing: 0) {
                    WegaCardHeader(icon: "touchid", title: tr("Touch ID dla poleceń administratora")) {
                        statusBadge
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(touchIDDescription)
                            .font(.wega(.callout))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // UX-01: jawne ujawnienie zakresu zmiany.
                        Text(tr("Działa też w Terminalu, nie tylko w Wedze."))
                            .font(.wega(.footnote))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let err = touchIDError {
                            Text(err)
                                .font(.wega(.subheadline))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // RC2-6/RC2-7: `sudo` reads these settings, so an unsafe or unproven policy
                        // leaves no command and no button in either state, only recoveryOS advice.
                        if let reason = touchIDController.recoveryOnlyReason {
                            touchIDNote(TouchIDEnableCopy.recoveryOnlyNote(for: reason), isWarning: true)
                        } else if touchIDController.showsEnableCommand {
                            if touchIDController.enableHelperOutdated {
                                touchIDNote(TouchIDEnableCopy.outdatedHelperAboveCommand)
                            }
                            manualCommand(
                                intro: tr("Bezpieczny zapis PAM wymaga podpisanego helpera. Jeśli jest niedostępny, uruchom poniższą transakcyjną komendę w Terminalu — wystarczy raz:"),
                                command: .enable)
                        } else if touchIDController.offersEnableButton {
                            Button {
                                Task { await enableTouchID() }
                            } label: {
                                if enablingTouchID {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label(tr("Używaj Touch ID zamiast hasła administratora"), systemImage: "touchid")
                                }
                            }
                            .disabled(enablingTouchID)
                            .controlSize(.small)
                        } else if touchIDState == .enabled {
                            switch touchIDController.disableOffer {
                            case .available:
                                if touchIDController.offersDisableButton {
                                    Button {
                                        Task { await disableTouchID() }
                                    } label: {
                                        if disablingTouchID {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Label(tr("Wyłącz Touch ID dla sudo"), systemImage: "touchid")
                                        }
                                    }
                                    .disabled(disablingTouchID)
                                    .controlSize(.small)
                                    localDirectoryWarning
                                }
                            case .helperOutdated:
                                touchIDNote(TouchIDDisableCopy.outdatedHelper)
                                disableWithoutHelper(otherwise: nil)
                            case .helperMissing:
                                disableWithoutHelper(otherwise: tr("Bez pomocnika Wegi wyłączysz je ręcznie."))
                            case .blocked(let refusal):
                                touchIDNote(TouchIDEnableCopy.unsafePolicyNote(refusal), isWarning: true)
                            case .unknown:
                                EmptyView()
                            }
                        }

                        // The recoveryOS note sends the user to the guide, so it has the link while
                        // Touch ID is off too.
                        if touchIDState == .enabled {
                            Link(tr("Jak wyłączyć Touch ID dla sudo"), destination: AppEndpoints.shared.touchIDGuideURL)
                                .font(.wega(.subheadline))
                        } else if touchIDController.recoveryOnlyReason != nil {
                            Link(tr("Jak naprawić ustawienia sudo"), destination: AppEndpoints.shared.touchIDGuideURL)
                                .font(.wega(.subheadline))
                        }

                        SettingsCardHint(text: cardHints[.touchID])
                    }
                    .padding(14)
                }
            }
            .id(SettingsCard.touchID)
        }
    }

    /// Without a helper that can do it (E.6): the disable command when the controller allows it, with
    /// the `/usr/local` warning under it; otherwise what the app's own read found, or `otherwise`.
    @ViewBuilder
    private func disableWithoutHelper(otherwise: String?) -> some View {
        if touchIDController.showsDisableCommand {
            manualCommand(
                intro: tr("Bez pomocnika Wegi wyłączysz Touch ID dla sudo tym poleceniem w Terminalu. Usuwa tylko dokładną dyrektywę i niczego nie zmienia, jeśli plik wygląda inaczej:"),
                command: .disable)
            localDirectoryWarning
        } else if let line = TouchIDDisableCopy.withoutCommand(
            plan: touchIDController.preflight.removalPlan, fallbackPath: touchIDController.preflight.fallbackPath
        ) ?? otherwise {
            touchIDNote(line)
        }
    }

    @ViewBuilder
    private var localDirectoryWarning: some View {
        if let path = touchIDController.preflight.unsafeLocalDirectory {
            touchIDNote(TouchIDDisableCopy.localDirectoryWarning(path: path))
        }
    }

    private func touchIDNote(_ text: String, isWarning: Bool = false) -> some View {
        Text(text)
            .font(.wega(.subheadline))
            .foregroundStyle(isWarning ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
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
                    Text(tr("Opcjonalny token zmniejsza przerwy przez limity zapytań GitHuba. Jest w pęku kluczy."))
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
                WegaCardHeader(icon: "lock.shield", title: tr("Pomocnik Wegi")) {
                    if helperBundleRefusal != nil {
                        WegaBadge(label: HelperBundleRefusalPresentation.badge, variant: .manual)
                    } else {
                        helperStatusBadge
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Pomocnik Wegi działa jako root i umie tylko cztery rzeczy: zainstalować zweryfikowany pakiet Wegi, włączyć albo wyłączyć Touch ID dla sudo, przywrócić kopię aplikacji sprzed aktualizacji, przenieść do Kosza aplikację należącą do roota. Przy każdym połączeniu sprawdza podpis Wegi. Jest opcjonalny."))
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let err = helperError {
                        Text(err)
                            .font(.wega(.subheadline))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let helperBundleRefusal { helperBundleRefusalSection(helperBundleRefusal) } else { helperActions }
                    SettingsCardHint(text: cardHints[.helper])
                }
                .padding(14)
            }
        }
        .id(SettingsCard.helper)
    }

    /// Z14: set while this copy of Wega may not use the helper; the card then replaces its actions.
    private var helperBundleRefusal: HelperBundleRefusalPresentation? {
        HelperBundleRefusalPresentation(trust: operations.helperBundleTrust, status: helperStatus, bundleName: InfoOperationsController.bundleName)
    }

    private func helperBundleRefusalSection(_ refusal: HelperBundleRefusalPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(refusal.headline + " " + refusal.reason)
                .font(.wega(.callout, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(refusal.explanation)
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(refusal.howTo)
                .font(.wega(.subheadline))
                .fixedSize(horizontal: false, vertical: true)
            if let note = refusal.registrationNote {
                Text(note)
                    .font(.wega(.subheadline))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Link(HelperBundleRefusalPresentation.releasesButton, destination: AppEndpoints.shared.latestReleaseURL)
                    .font(.wega(.callout))
                if refusal.offersRemoval {
                    Button(role: .destructive) {
                        Task { await removeHelper() }
                    } label: { Label(tr("Usuń pomocnika"), systemImage: "trash") }
                        .controlSize(.small)
                        .disabled(helperBusy)
                }
                Spacer()
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
                } label: { Label(tr("Usuń pomocnika"), systemImage: "trash") }
                    .controlSize(.small)
                    .disabled(helperBusy)
            case .requiresApproval:
                Button {
                    operations.openLoginItemsSettings()
                } label: { Label(tr("Otwórz Ustawienia → Elementy logowania"), systemImage: "gearshape") }
                    .controlSize(.small)
                Button(tr("Sprawdź ponownie")) {
                    cardHints[.helper] = nil
                    operations.refreshHelperStatus()
                }
                .controlSize(.small)
            default:
                Button {
                    Task { await installHelper() }
                } label: {
                    if helperBusy { ProgressView().controlSize(.small) }
                    else { Label(tr("Zainstaluj pomocnika"), systemImage: "lock.shield") }
                }
                .controlSize(.small)
                .disabled(helperBusy)
            }
            Spacer()
        }
    }

    private func installHelper() async {
        await operations.installHelper(onWegaState: relay(.helper))
    }

    private func removeHelper() async {
        cardHints[.helper] = nil
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
            return tr("Polecenia administratora potwierdzasz odciskiem palca zamiast hasła — także aktualizacje casków, które o nie proszą.")
        case .available:
            return tr("Po włączeniu Homebrew poprosi o odcisk palca zamiast hasła. Włączenie raz wymaga uprawnień administratora.")
        case .notSupported:
            return ""
        }
    }

    /// A `sudo` command for Terminal when the helper cannot act: the exact one-liner, with buttons to
    /// copy it, to open Terminal.app pre-armed with it and to check again. The enum, never text,
    /// travels to Terminal, so what opens is what the card shows (RC2-8).
    @ViewBuilder
    private func manualCommand(intro: String, command: TouchIDManualCommand) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(intro)
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(command.text)
                .font(.wega(.subheadline, monospaced: true))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.wegaRecessedSurface, in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command.text, forType: .string)
                } label: {
                    Label(tr("Skopiuj polecenie"), systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button {
                    openInTerminal(command)
                } label: {
                    Label(tr("Otwórz w Terminalu"), systemImage: "terminal")
                }
                .controlSize(.small)

                Spacer()

                Button(tr("Sprawdź ponownie")) {
                    cardHints[.touchID] = nil
                    touchIDController.refresh()
                    Task { await touchIDController.refreshDisableOffer() }
                }
                .controlSize(.small)
            }
        }
    }

    private func openInTerminal(_ command: TouchIDManualCommand) {
        touchIDController.openInTerminal(command)
    }

    // MARK: - Self-update (Wega dogfooding its own GitHub releases)

    @ViewBuilder
    private var selfUpdateRow: some View {
        HStack(spacing: 10) {
            // `selfUpdate` (== `selfUpdateController.result`) is nil for `.idle`, `.checking` and
            // `.installedPendingRestart` alike, so that terminal state needs its own case here —
            // otherwise it could never render (it would fall into the bare check button below).
            switch selfUpdateState {
            case .installationUncertain:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.wegaDanger)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Nie potwierdzono zakończenia instalacji"))
                        .font(.wega(.callout, weight: .semibold))
                    Text(SelfUpdatePresentation.uncertainInstallationDetail(fromRefusedCopy: selfUpdateController.pendingInstallationNeedsInstalledCopy))
                        .font(.wega(.footnote))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(tr("Sprawdź stan instalacji")) {
                    Task {
                        await selfUpdateController.reconcileInstallation(onWegaState: relay(.selfUpdate))
                    }
                }
                .disabled(selfUpdateController.isReconcilingInstallation)
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
                    SelfUpdateNoteDisclosure(note: note)
                }
                if history.omitted > 0 {
                    Text(trp("…i %@ wcześniejszych wydań", history.omitted))
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                }
            }
        case .unavailable:
            Text(tr("Nie udało się pobrać notatek wydania"))
                .font(.wega(.subheadline))
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
        await selfUpdateController.apply(action, version: version, onWegaState: relay(.selfUpdate))
    }

    private func enableTouchID() async {
        await touchIDController.enable(onWegaState: relay(.touchID))
        await touchIDController.refreshDisableOffer()
    }

    private func disableTouchID() async {
        await touchIDController.disable(onWegaState: relay(.touchID))
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

                SettingsCardHint(text: cardHints[.selfUpdate])
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

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
                    Button(tr("Zgłoś błąd")) { reportController = BugReportController(entries: []) }
                        .buttonStyle(.link)
                        .font(.wega(.body))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .id(SettingsCard.selfUpdate)
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
            }

            Text(tr("Zapisuje paczkę zip z oboma plikami logów, wersjami, wykrytymi menedżerami, statusem harmonogramu i historią aktualizacji. Ścieżki, tokeny i nazwy użytkownika są zastąpione znacznikami; nic nie jest nigdzie wysyłane."))
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DiagnosticsExportStatusRow(controller: diagnosticsExport)
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
