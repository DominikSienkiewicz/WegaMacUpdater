import SwiftUI
import MacUpdaterCore

private enum UpdateStatus { case ready, checking, results }

/// The update currently shown in the inspector pane — either a package-manager-tracked
/// item (brew/mas/npm) or a manually-checked app. Module-internal (not `private`) so
/// `InspectorPane`, in its own file, can render it.
enum InspectedUpdate: Equatable {
    case outdated(OutdatedItem, iconPath: URL?)
    case manual(ManualOutdatedApp)
}

struct UpdateView: View {
    var onWegaState:   ((WegaState) -> Void)?
    var onBadgeChange: ((Int) -> Void)?
    var onNavigate:    ((SidebarTab) -> Void)?
    var onErrorCount:  ((Int) -> Void)?
    /// Drives the sidebar tab icon: spins while busy, then green (ok) / red (error).
    var onActivity:    ((UpdateActivity) -> Void)?
    /// Drives the window's status footer: last scan time + count of manual updates
    /// whose release notes look like a security fix.
    var onFooterInfo:  ((Date?, Int) -> Void)? = nil
    /// Which category of updates to show, driven by the sidebar. Defaults to
    /// showing everything until the sidebar selection wires this up.
    var updateFilter:     UpdateFilter = .all
    /// Reports (apps count, CLI count) after each scan, for sidebar badges.
    var onCategoryCounts: ((Int, Int) -> Void)? = nil

    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var policies: UpdatePolicyStore
    @Environment(\.openSettings) private var openSettings

    @State private var pinTarget:      PinRequest?       = nil
    @State private var status:         UpdateStatus      = .ready
    @State private var brewOutdated:   BrewOutdated?
    @State private var masOutdated:    [MasOutdatedApp]  = []
    @State private var npmOutdated:    [NpmGlobalOutdated] = []
    @State private var manualOutdated: [ManualOutdatedApp] = []
    @State private var manualBusy:     String?
    @State private var brewLog:        [String]          = []
    @State private var showLog:        Bool              = false
    @State private var selected:           Set<String>       = []
    @State private var updating:           Bool              = false
    @State private var errorMessage:       String?
    @State private var lastCheck:          Date?
    @State private var banner:             BannerData?
    @State private var restartCandidates:  [RestartInfo]     = []
    @State private var restartBusy:        String?
    @State private var caskIconPaths:      [String: URL]     = [:]
    @State private var caskDownloads:      [String: CaskDownloadInfo] = [:]   // FEAT-03
    @State private var inspectedKey:       String?           = nil

    private let processes = RunningProcessService()

    // Keys carry a source tag ("f:", "c:", "a:", "n:"); see UpdatePlanner.
    // Items the user has ignored or pinned below the available version are filtered out.
    private var allItems: [OutdatedItem] {
        UpdatePlanner.applyPolicies(
            UpdatePlanner.outdatedItems(brew: brewOutdated, mas: masOutdated, npm: npmOutdated),
            policies: policies.policiesMap
        )
    }

    /// Manual updates with ignore/pin rules applied.
    private var visibleManual: [ManualOutdatedApp] {
        UpdatePlanner.applyPolicies(manualOutdated, policies: policies.policiesMap)
    }

    /// The update currently shown in the inspector pane, resolved from `inspectedKey`
    /// against the same lists the list column renders — so the inspector always
    /// reflects live data (e.g. after a rescan) rather than a stale snapshot.
    private var inspectedUpdate: InspectedUpdate? {
        guard let key = inspectedKey else { return nil }
        if let item = allItems.first(where: { $0.key == key }) {
            return .outdated(item, iconPath: caskIconPaths[item.name])
        }
        if let app = visibleManual.first(where: { "m:" + $0.path.path == key }) {
            return .manual(app)
        }
        return nil
    }


    var body: some View {
        content
            .sheet(item: $pinTarget) { req in
                PinVersionSheet(request: req) { version in
                    policies.pin(key: req.key, name: req.name, version: version)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .ready:    readyView
        case .checking: checkingView
        case .results:  resultsView
        }
    }

    // MARK: Ready
    private var readyView: some View {
        EmptyHero(
            pose: .idle,
            title: tr("Sprawdźmy, co się zestarzało"),
            message: tr("Wega zajrzy do Homebrew oraz Mac App Store i powie, co warto odświeżyć."),
            action: AnyView(
                Button { Task { await runCheck() } } label: {
                    Label(tr("Sprawdź aktualizacje"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
                .controlSize(.large)
            )
        )
    }

    // MARK: Checking
    private var checkingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(["brew update", "brew outdated", "brew outdated --cask --greedy", "mas outdated", "sparkle · cask check"].enumerated()), id: \.offset) { idx, cmd in
                CheckingBar(command: cmd, delay: Double(idx) * 0.2)
            }
            SniffingScene(
                caption: tr("Wega węszy po Homebrew…"),
                thoughts: [
                    tr("Czy ten cask jest świeży?"),
                    tr("Coś tu pachnie aktualizacją"),
                    tr("Sniff sniff… brew outdated"),
                    tr("Hmm, znajomy zapach Sparkle"),
                    tr("SHA256 się zgadza?"),
                    tr("Łapię trop wersji"),
                    "0x4A 0x65 0x6C 0x6C 0x79",
                    tr("Mhm… nowa wersja?"),
                    tr("Info.plist… mhm"),
                    tr("Ten cask wymaga odświeżenia")
                ]
            )
            .padding(.top, 16)
        }
        .padding(24)
    }

    // MARK: Results
    private var resultsView: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(allItems.isEmpty ? tr("Wszystko aktualne") : trf("%@ aktualizacji do zainstalowania", "\(allItems.count)"))
                        .font(.system(size: 18, weight: .semibold))
                    if let d = lastCheck {
                        HStack(spacing: 4) {
                            Text(trf("Sprawdzono %@", "\(d.formatted(date: .omitted, time: .shortened))"))
                            Text("·")
                            Text("brew + mas").font(.system(size: 11, design: .monospaced))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button { Task { await runCheck() } } label: {
                    Label(tr("Sprawdź ponownie"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(updating || status == .checking)

                if !allItems.isEmpty {
                    Button { Task { await runUpdate() } } label: {
                        if updating {
                            ProgressView().controlSize(.small)
                        } else if selected.isEmpty {
                            Label(trf("Zaktualizuj wszystkie (%@)", "\(allItems.count)"), systemImage: "arrow.down.circle.fill")
                        } else {
                            Label(trf("Zaktualizuj wybrane (%@)", "\(selected.count)"), systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wegaHoney)
                    .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
                    .disabled(updating)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let b = banner {
                BannerView(
                    data: b,
                    onAction: { action in
                        switch action {
                        case .openLogs: onNavigate?(.logs)
                        case .openSettings:
                            openSettings()
                        }
                    },
                    onClose: { banner = nil }
                )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 0) {
                listColumn
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                Divider()
                InspectorPane(update: inspectedUpdate)
                    .frame(width: 340)
            }
        }
    }

    @ViewBuilder
    private var listColumn: some View {
        if allItems.isEmpty && visibleManual.isEmpty && restartCandidates.isEmpty {
            EmptyHero(pose: .sleep, title: tr("Wszystko aktualne"), message: tr("Wega się zdrzemnie. Zajrzymy znowu za jakiś czas."), compact: true)
        } else if filterHasContent(updateFilter) || !restartCandidates.isEmpty {
            VStack(spacing: 0) {
                // Select-all row
                HStack(spacing: 10) {
                    Image(systemName: selectAllSymbol)
                        .foregroundStyle(selected.isEmpty ? .secondary : Color.wegaHoney)
                        .font(.system(size: 16))
                        .onTapGesture { toggleAll() }
                        .accessibilityLabel(tr("Zaznacz wszystko"))
                        .accessibilityAddTraits(.isButton)
                    Text(selected.isEmpty ? tr("Zaznacz wszystko") : trf("%@ z %@ zaznaczonych", "\(selected.count)", "\(allItems.count)"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                ScrollView {
                    LazyVStack(spacing: 12) {
                        let formulae = allItems.filter { $0.kind == .formula }
                        let casks    = allItems.filter { $0.kind == .cask }
                        let store    = allItems.filter { $0.kind == .appStore }
                        let npmPkgs  = allItems.filter { $0.kind == .npm }
                        if !formulae.isEmpty && updateFilter.allowsCli { UpdateSection(title: tr("Homebrew Formulae"), subtitle: tr("narzędzia CLI"),  icon: "terminal",  items: formulae, selected: $selected, inspectedKey: inspectedKey, onIgnore: ignoreItem, onPin: requestPin, onInspect: { inspectedKey = $0.key }) }
                        if !casks.isEmpty && updateFilter.allowsApps {
                            UpdateSection(title: tr("Homebrew Casks"), subtitle: tr("aplikacje .app"), icon: "app.gift", items: casks, iconPaths: caskIconPaths, selected: $selected, inspectedKey: inspectedKey, onIgnore: ignoreItem, onPin: requestPin, onInspect: { inspectedKey = $0.key })
                            caskTransparencyNote(casks: casks)
                        }
                        if !store.isEmpty && updateFilter.allowsApps    { UpdateSection(title: tr("Mac App Store"),     subtitle: tr("via mas-cli"),      icon: "bag",      items: store,    selected: $selected, inspectedKey: inspectedKey, onIgnore: ignoreItem, onPin: requestPin, onInspect: { inspectedKey = $0.key }) }
                        if !npmPkgs.isEmpty && updateFilter.allowsCli  { UpdateSection(title: tr("npm globalne"),      subtitle: tr("pakiety -g"),       icon: "shippingbox", items: npmPkgs, selected: $selected, inspectedKey: inspectedKey, onIgnore: ignoreItem, onPin: requestPin, onInspect: { inspectedKey = $0.key }) }
                        // Group manual updates by INSTALL ORIGIN (same axis the Inventory
                        // window labels), not by update source. A self-updating Homebrew
                        // cask (Docker, Postman, ChatGPT…) stays under "Homebrew Casks" so
                        // both windows agree it's Brew — only genuinely non-package-manager
                        // apps land under "Ręcznie zainstalowane".
                        let manualGroups = UpdatePlanner.groupManual(visibleManual)
                        let brewManual = updateFilter.isSecurityOnly ? manualGroups.brew.filter(isSecurityApp) : manualGroups.brew
                        if !brewManual.isEmpty && updateFilter != .cli {
                            ManualUpdateSection(
                                items: brewManual,
                                busyToken: manualBusy,
                                onInstall: { token in Task { await installManual(token: token) } },
                                title: tr("Homebrew Casks"),
                                icon: "app.gift",
                                subtitle: tr("samoaktualizujące się"),
                                caption: tr("Homebrew nie pilnuje wersji tych apek (auto_updates) — robią to same. Wega sprawdza je u źródła."),
                                inspectedKey: inspectedKey,
                                onIgnore: ignoreManual,
                                onPin: requestPinManual,
                                onInspect: { inspectedKey = "m:" + $0.path.path }
                            )
                        }
                        let manualOnly = updateFilter.isSecurityOnly ? manualGroups.manual.filter(isSecurityApp) : manualGroups.manual
                        if !manualOnly.isEmpty && updateFilter != .cli {
                            ManualUpdateSection(
                                items: manualOnly,
                                busyToken: manualBusy,
                                onInstall: { token in Task { await installManual(token: token) } },
                                title: tr("Ręcznie zainstalowane"),
                                icon: "sparkle",
                                inspectedKey: inspectedKey,
                                onIgnore: ignoreManual,
                                onPin: requestPinManual,
                                onInspect: { inspectedKey = "m:" + $0.path.path }
                            )
                        }
                        if !restartCandidates.isEmpty {
                            RestartSection(
                                candidates: restartCandidates,
                                busyProcess: restartBusy,
                                onRestart: { info in Task { await restartApp(info) } }
                            )
                        }
                        if showLog {
                            BrewLogPanel(lines: brewLog) { showLog = false }
                        }
                    }
                    .padding(16)
                }
            }
        } else {
            EmptyHero(
                pose: .idle,
                title: tr("Nic w tej kategorii"),
                message: tr("W tej kategorii nie ma teraz aktualizacji. Przełącz kategorię w panelu bocznym."),
                compact: true
            )
        }
    }

    private var selectAllSymbol: String {
        switch UpdatePlanner.selectAllState(selectedCount: selected.count, totalCount: allItems.count) {
        case .none:    return "square"
        case .all:     return "checkmark.square.fill"
        case .partial: return "minus.square.fill"
        }
    }

    private func toggleAll() {
        selected = UpdatePlanner.toggledAll(selected: selected, allKeys: allItems.map(\.key))
    }

    // MARK: Ignore / pin

    private func ignoreItem(_ item: OutdatedItem) {
        policies.ignore(key: item.policyKey, name: item.name)
        selected.remove(item.key)
    }

    private func requestPin(_ item: OutdatedItem) {
        pinTarget = PinRequest(key: item.policyKey, name: item.name, suggestedVersion: item.from ?? item.to ?? "")
    }

    private func ignoreManual(_ app: ManualOutdatedApp) {
        policies.ignore(key: app.policyKey, name: app.name)
    }

    private func requestPinManual(_ app: ManualOutdatedApp) {
        pinTarget = PinRequest(key: app.policyKey, name: app.name, suggestedVersion: app.installedVersion ?? app.availableVersion ?? "")
    }

    /// True when a manual app's release notes look like a security fix — used to
    /// narrow the manual sections when `updateFilter.isSecurityOnly`.
    private func isSecurityApp(_ app: ManualOutdatedApp) -> Bool {
        app.releaseNotes.map { ReleaseNotesTriage.heuristic($0).isLikelySecurityFix } ?? false
    }

    /// Whether the given filter would surface at least one update section.
    private func filterHasContent(_ filter: UpdateFilter) -> Bool {
        switch filter {
        case .all:      return !allItems.isEmpty || !visibleManual.isEmpty
        case .apps:     return allItems.contains { $0.kind.category == .apps } || !visibleManual.isEmpty
        case .cli:      return allItems.contains { $0.kind.category == .cli }
        case .security: return visibleManual.contains(where: isSecurityApp)
        }
    }

    // MARK: FEAT-03 — transparentność pobrania
    @ViewBuilder
    private func caskTransparencyNote(casks: [OutdatedItem]) -> some View {
        let noCheck = casks.filter { caskDownloads[$0.name]?.hasChecksum == false }
        if !noCheck.isEmpty {
            WegaCard {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.shield").foregroundStyle(Color.wegaDanger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Bez weryfikacji sumy kontrolnej"))
                            .font(.system(size: 12, weight: .semibold))
                        Text(trf("Homebrew zainstaluje bez sprawdzenia sumy: %@", "\(noCheck.map(\.name).joined(separator: ", "))"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
    }

}

// MARK: - Scan & update actions
//
// Split into an extension (same file, so `private` state stays accessible) to keep the
// `UpdateView` struct body within SwiftLint's type_body_length budget.
extension UpdateView {
    private func runCheck(emitActivity: Bool = true) async {
        status = .checking
        errorMessage = nil
        if emitActivity { onActivity?(.scanning) }
        WegaLog.info(.scanner, tr("Skan rozpoczęty"))
        onWegaState?(WegaState(pose: .sniff, line: tr("Węszę po Homebrew…")))

        // Refresh brew metadata before asking what is outdated — otherwise a
        // newly-released cask/formula version that hasn't landed locally yet
        // would be missed even though `brew info` against the API shows it.
        _ = try? await model.brewService.update()

        // Usuń stale casks zanim sprawdzimy co jest outdated
        let installedTokens = (try? await model.brewService.installedCasks()) ?? []
        if !installedTokens.isEmpty {
            let installInfo = (try? await model.brewService.caskInstallationInfo(tokens: Array(installedTokens))) ?? []
            let staleTokens = StaleCaskDetector().staleCasks(from: installInfo)
            for token in staleTokens {
                _ = try? await model.brewService.uninstallCask(token: token, force: true)
            }
        }

        // Count sources whose check genuinely failed (vs. a tool that's simply not
        // installed, which is "not applicable", not a failure). Drives the
        // "couldn't check" vs "up to date" distinction below.
        var failedSources = 0
        // Names of the top-level sources that genuinely went silent, for the scan-end
        // log (each manual-checker failure is logged individually by ManualUpdateScanner).
        var silentSources: [String] = []

        do { brewOutdated = try await model.brewService.outdatedGreedy() }
        catch { errorMessage = error.localizedDescription; brewOutdated = nil; failedSources += 1
                silentSources.append("brew outdated")
                WegaLog.error(.homebrew, "brew outdated: \(error.localizedDescription)") }

        do { masOutdated = try await model.masService.outdated() }
        catch MasServiceError.masNotFound { masOutdated = [] }
        catch { masOutdated = []; failedSources += 1
                silentSources.append("Mac App Store")
                WegaLog.error(.app, "mas outdated: \(error.localizedDescription)") }

        do { npmOutdated = try await model.npmService.outdated() }
        catch NpmServiceError.npmNotFound { npmOutdated = [] }
        catch { npmOutdated = []; failedSources += 1
                silentSources.append("npm")
                WegaLog.error(.network, "npm outdated: \(error.localizedDescription)") }

        let brewOutdatedCasks = Set(brewOutdated?.casks.map(\.name) ?? [])
        let scan = await scanManualUpdates(brewOutdatedCasks: brewOutdatedCasks)
        manualOutdated = scan.apps
        failedSources += scan.failedChecks
        if scan.failedChecks > 0 { silentSources.append("ręczne checki (\(scan.failedChecks))") }

        // Resolve icon paths for outdated casks, and drop entries whose real
        // bundle version already matches `current_version` (self-updating apps
        // like Chrome bump their bundle behind brew's back).
        if let casks = brewOutdated?.casks, !casks.isEmpty {
            let infos = (try? await model.brewService.caskInstallationInfo(tokens: casks.map(\.name))) ?? []

            let drifted = BrewCaskDriftFilter().driftedTokens(outdated: casks, installationInfo: infos)
            if !drifted.isEmpty, var updated = brewOutdated {
                updated.casks.removeAll { drifted.contains($0.name) }
                brewOutdated = updated
            }

            let home = FileManager.default.homeDirectoryForCurrentUser
            var paths: [String: URL] = [:]
            for info in infos where !drifted.contains(info.token) {
                for artifact in info.appArtifacts {
                    let system = SystemPaths.applicationsDirectory.appendingPathComponent(artifact)
                    let user   = home.appendingPathComponent("Applications/\(artifact)")
                    if FileManager.default.fileExists(atPath: system.path) {
                        paths[info.token] = system; break
                    } else if FileManager.default.fileExists(atPath: user.path) {
                        paths[info.token] = user; break
                    }
                }
            }
            caskIconPaths = paths
        }

        // FEAT-03: transparentność pobrania (host + checksum) dla outdated casków.
        if let casks = brewOutdated?.casks, !casks.isEmpty {
            let infos = (try? await model.brewService.caskDownloadInfo(tokens: casks.map(\.name))) ?? []
            caskDownloads = Dictionary(infos.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            caskDownloads = [:]
        }

        lastCheck = Date()
        status    = .results

        finishScan(emitActivity: emitActivity, silentSources: silentSources, failedSources: failedSources)
    }

    /// Reports a finished scan: structured log (breakdown + per-item lines), the tab-icon
    /// status (green/red, unless suppressed for the upgrade flow), the result banner, and
    /// the badge/error counts. Split out of `runCheck` to keep that method's complexity down.
    private func finishScan(emitActivity: Bool, silentSources: [String], failedSources: Int) {
        let total = allItems.count + visibleManual.count
        let breakdown = ScanLog.breakdown(items: allItems, manual: visibleManual)
        let silent = silentSources.isEmpty
            ? "wszystkie źródła odpowiedziały"
            : "milczały: \(silentSources.joined(separator: ", "))"
        WegaLog.info(.scanner, "Skan zakończony: \(total) aktualizacji (\(breakdown)) — \(silent)")
        for line in ScanLog.foundLines(items: allItems, manual: visibleManual) {
            WegaLog.info(.scanner, "• \(line)")
        }
        let scanState = UpdatePlanner.scanState(updateCount: total, failedChecks: failedSources)
        // Tab-icon status: green when the scan completed, red when a source failed.
        // Suppressed when called from `runUpdate` (emitActivity == false), which owns
        // the icon for the whole upgrade flow and sets the final state itself.
        if emitActivity {
            switch scanState {
            case .upToDate, .outdated:          onActivity?(.success)
            case .checkFailed, .partialFailure: onActivity?(.error)
            }
        }
        switch scanState {
        case .upToDate:
            if let msg = errorMessage {
                banner = BannerData(variant: .danger, title: tr("Błąd Homebrew"), message: msg, action: .openLogs)
            }
            onWegaState?(WegaState(pose: .happy, line: tr("Wszystko aktualne. Idę się zdrzemnąć.")))
        case .outdated(let n):
            if let msg = errorMessage {
                banner = BannerData(variant: .danger, title: tr("Błąd Homebrew"), message: msg, action: .openLogs)
            }
            onWegaState?(WegaState(pose: .alert, line: trf("Znalazłam %@ rzeczy do uporządkowania.", "\(n)")))
        case .checkFailed:
            banner = BannerData(variant: .danger,
                                title: tr("Nie udało się sprawdzić aktualizacji"),
                                message: errorMessage ?? tr("Część źródeł nie odpowiedziała — sprawdź połączenie z internetem i spróbuj ponownie."),
                                action: .openLogs)
            onWegaState?(WegaState(pose: .sad, line: tr("Nie dowęszyłam się — chyba nie ma internetu.")))
        case .partialFailure(let updates, let failed):
            banner = BannerData(variant: .danger,
                                title: tr("Lista może być niepełna"),
                                message: trf("Znalazłam %@ aktualizacji, ale %@ źródeł nie odpowiedziało — sprawdź połączenie i odśwież.", "\(updates)", "\(failed)"),
                                action: .openLogs)
            onWegaState?(WegaState(pose: .alert, line: trf("Znalazłam %@, ale część źródeł milczy.", "\(updates)")))
        }
        onBadgeChange?(allItems.count)
        onErrorCount?(failedSources)
        let securityCount = visibleManual.filter(isSecurityApp).count
        onFooterInfo?(lastCheck, securityCount)
        let appsCount = allItems.filter { $0.kind.category == .apps }.count + visibleManual.count
        let cliCount  = allItems.filter { $0.kind.category == .cli }.count
        onCategoryCounts?(appsCount, cliCount)
    }

    private func scanManualUpdates(brewOutdatedCasks: Set<String> = []) async -> (apps: [ManualOutdatedApp], failedChecks: Int) {
        await ManualUpdateScanner(brewService: model.brewService).scan(brewOutdatedCasks: brewOutdatedCasks)
    }

    private func installManual(token: String) async {
        guard manualBusy == nil else { return }
        manualBusy = token
        onActivity?(.scanning)
        let installArgs = BrewService.adoptCaskArguments(token: token)
        brewLog = ["$ brew " + installArgs.joined(separator: " ")]
        showLog = true
        WegaLog.info(.homebrew, "Uruchamiam: brew \(installArgs.joined(separator: " "))")
        onWegaState?(WegaState(pose: .sniff, line: trf("Instaluję %@ przez Brew…", "\(token)")))

        do {
            let stream = try model.brewService.events(arguments: installArgs)
            var exitCode: Int32 = 0
            for try await event in stream {
                switch event {
                case .stdout(let chunk), .stderr(let chunk):
                    let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
                    brewLog.append(contentsOf: lines)
                case .finished(let result):
                    exitCode = result.exitCode
                }
            }
            if exitCode == 0 {
                manualOutdated.removeAll {
                    if case .cask(let t) = $0.source { return t == token }
                    return false
                }
                banner = BannerData(variant: .success, title: trf("Zaktualizowano %@", "\(token)"), message: tr("Teraz zarządzany przez Homebrew."))
                onActivity?(.success)
                onWegaState?(WegaState(pose: .happy, line: trf("%@ zaktualizowany i pod opieką Brew.", "\(token)")))
                WegaLog.info(.homebrew, "Zainstalowano \(token) (brew cask)")
            } else {
                banner = BannerData(variant: .danger, title: trf("Błąd instalacji %@", "\(token)"), message: tr("Sprawdź logi poniżej."))
                onActivity?(.error)
                onWegaState?(WegaState(pose: .idle, line: trf("Coś poszło nie tak z %@.", "\(token)")))
                let reason = ScanLog.brewErrorReason(from: brewLog).map { ": \($0)" } ?? ""
                WegaLog.error(.homebrew, "Instalacja \(token) nieudana (kod \(exitCode))\(reason)")
            }
        } catch {
            brewLog.append("error: \(error.localizedDescription)")
            banner = BannerData(variant: .danger, title: tr("Błąd instalacji"), message: error.localizedDescription)
            onActivity?(.error)
            onWegaState?(WegaState(pose: .idle, line: trf("Coś poszło nie tak z %@.", "\(token)")))
            WegaLog.error(.homebrew, "Instalacja \(token): \(error.localizedDescription)")
        }
        manualBusy = nil
    }

    private func runUpdate() async {
        updating = true
        onActivity?(.scanning)
        brewLog = []
        showLog = true
        onWegaState?(WegaState(pose: .sniff, line: tr("Aktualizuję, chwila…")))

        let plan          = UpdatePlanner.plan(selectedKeys: selected, allKeys: allItems.map(\.key))
        let formulaNames  = plan.formulaNames
        let caskNames     = plan.caskNames
        let npmNames      = plan.npmNames
        let hasMasItems   = plan.includesMas
        let n             = plan.count

        // Pre-capture which casks being updated are currently running
        var candidates: [RestartInfo] = []
        for token in caskNames {
            if let info = MacUpdaterConstants.restartMap[token], await isProcessRunning(info.processName) {
                candidates.append(info)
            }
        }

        // FEAT-07: dla casków (duże pobrania) doradczo ostrzeż przy złych warunkach
        // (łącze taryfowe / throttling). Akcja jest user-initiated → kontynuujemy.
        if !caskNames.isEmpty {
            let (net, pow) = await LiveConditions.snapshot()
            if case let .postpone(reason) = DownloadGate.decide(
                sizeBytes: 200 * 1024 * 1024 + 1, network: net, power: pow) {
                brewLog.append("⚠️ " + trf("Niekorzystne warunki pobierania (%@) — kontynuuję na żądanie.", "\(reason)"))
                onWegaState?(WegaState(pose: .alert, line: tr("Uwaga: kosztowne łącze lub throttling — pobieram mimo to.")))
            }
        }

        var outcomes: [BrewUpgradeOutcome] = []

        // Brew upgrade — formulae
        if !formulaNames.isEmpty {
            let args = ["upgrade"] + formulaNames
            outcomes.append(await runBrewUpgrade(arguments: args))
        }

        // Brew upgrade — casks (FEAT-05 snapshot przed, canary/rollback + FEAT-04 ledger po)
        if !caskNames.isEmpty {
            let snapshots = snapshotCasks(caskNames)
            let args = ["upgrade", "--cask"] + caskNames
            var caskOutcome = await runBrewUpgrade(arguments: args)

            // Auto-recover an interrupted upgrade: if a cask bailed because a stale
            // staged app from a previous, cut-short upgrade is in the way ("already an
            // App at …"), retry just those casks once with --force, which overwrites
            // the leftover. Without this they fail on every attempt until cleaned by hand.
            let retryTokens = caskOutcome.tokensRetryableWithForce
            if !retryTokens.isEmpty {
                brewLog.append("↻ " + trf("Przerwana aktualizacja (%@) — ponawiam z --force.", "\(retryTokens.joined(separator: ", "))"))
                WegaLog.info(.homebrew, "Przerwana aktualizacja casku — ponawiam z --force: \(retryTokens.joined(separator: ", "))")
                let retryOutcome = await runBrewUpgrade(arguments: ["upgrade", "--cask", "--force"] + retryTokens)
                caskOutcome = BrewUpgradeOutcome.merging(original: caskOutcome, forcedRetry: retryOutcome, retriedTokens: retryTokens)
            }

            outcomes.append(caskOutcome)
            await postCaskUpgrade(caskNames, snapshots: snapshots)
        }

        // npm global upgrade — one package at a time (npm semantics).
        for pkg in npmNames {
            outcomes.append(await runNpmUpgrade(name: pkg))
        }

        // MAS upgrade
        if hasMasItems {
            brewLog.append("$ mas upgrade")
            do {
                let result = try await model.masService.upgrade()
                let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
                brewLog.append(contentsOf: lines)
            } catch {
                brewLog.append("error: \(error.localizedDescription)")
                WegaLog.error(.app, "mas upgrade: \(error.localizedDescription)")
            }
        }

        _ = try? await model.brewService.cleanup()

        selected.removeAll()
        restartCandidates = candidates

        // Re-query brew/mas so the list reflects reality, not optimistic clearing.
        // If a cask failed (e.g. "App source not there"), it will still appear here.
        // Suppress its icon signal — the upgrade outcome below sets the final state.
        await runCheck(emitActivity: false)

        updating = false

        let summary = UpdatePlanner.summarize(outcomes: outcomes)
        let failedTokens = summary.failedTokens
        let needsSudoPassword = summary.needsSudoPassword
        if summary.anyFailure {
            let baseDetail = failedTokens.isEmpty
                ? tr("Brew zgłosił błąd — sprawdź log poniżej.")
                : trf("Nie udało się: %@. Szczegóły w logu.", "\(failedTokens.joined(separator: ", "))")
            let detail = needsSudoPassword
                ? trf("%@ Cask wymaga hasła administratora. Włącz Touch ID, żeby autoryzować aktualizacje odciskiem — bez wpisywania hasła.", "\(baseDetail)")
                : baseDetail
            banner = BannerData(variant: .danger,
                                title: tr("Aktualizacja niekompletna"),
                                message: detail,
                                action: needsSudoPassword ? .openSettings : nil)
            onActivity?(.error)
            onWegaState?(WegaState(pose: .alert, line: tr("Część pakietów się nie zaktualizowała.")))
            WegaLog.error(.homebrew, "Aktualizacja niekompletna: \(failedTokens.isEmpty ? "Brew zgłosił błąd" : failedTokens.joined(separator: ", "))")
            // Surface *why* each upgrade failed — the brew error block, not just the
            // token name — so the log explains the failure instead of only flagging it.
            for detail in summary.failureDetails {
                WegaLog.error(.homebrew, detail)
            }
        } else {
            banner = BannerData(variant: .success, title: trf("Zaktualizowano %@ pakietów", "\(n)"), message: tr("Wszystko gotowe."))
            onActivity?(.success)
            onWegaState?(WegaState(pose: .happy, line: trf("Gotowe! %@ pakietów odświeżonych.", "\(n)")))
            WegaLog.info(.homebrew, "Zaktualizowano \(n) pakietów")
        }
    }

    /// Runs `brew <arguments>` streaming output to the log, and returns an
    /// outcome that reflects whether brew *actually* succeeded — exit code 0
    /// alone is unreliable for cask upgrades.
    private func runBrewUpgrade(arguments: [String]) async -> BrewUpgradeOutcome {
        brewLog.append("$ brew \(arguments.joined(separator: " "))")
        var captured = ""
        var exitCode: Int32 = 0
        do {
            let stream = try model.brewService.events(arguments: arguments)
            for try await event in stream {
                switch event {
                case .stdout(let chunk), .stderr(let chunk):
                    captured += chunk
                    let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
                    brewLog.append(contentsOf: lines)
                    if brewLog.count > 500 { brewLog.removeFirst(brewLog.count - 500) }
                case .finished(let result):
                    exitCode = result.exitCode
                }
            }
        } catch {
            brewLog.append("error: \(error.localizedDescription)")
            return BrewUpgradeOutcome(exitCode: -1, failedTokens: [], errorLines: [error.localizedDescription])
        }
        return BrewUpgradeOutcome.analyze(exitCode: exitCode, output: captured)
    }

    private func runNpmUpgrade(name: String) async -> BrewUpgradeOutcome {
        brewLog.append("$ npm install -g \(name)@latest")
        var exitCode: Int32 = 0
        do {
            let stream = try model.npmService.upgradeEvents(name: name)
            for try await event in stream {
                switch event {
                case .stdout(let chunk), .stderr(let chunk):
                    let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
                    brewLog.append(contentsOf: lines)
                    if brewLog.count > 500 { brewLog.removeFirst(brewLog.count - 500) }
                case .finished(let result):
                    exitCode = result.exitCode
                }
            }
        } catch {
            brewLog.append("error: \(error.localizedDescription)")
            return BrewUpgradeOutcome(exitCode: -1, failedTokens: [name], errorLines: [error.localizedDescription])
        }
        return BrewUpgradeOutcome(
            exitCode: exitCode,
            failedTokens: exitCode == 0 ? [] : [name],
            errorLines: []
        )
    }

    // MARK: FEAT-05 (rollback) + FEAT-04 (watchdog Team ID)

    /// FEAT-05: instant COW clone (clonefile) of each cask's app before upgrade,
    /// so a bad upgrade can be rolled back. Returns token→snapshot URL.
    private func snapshotCasks(_ tokens: [String]) -> [String: URL] {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wega-rollback", isDirectory: true)
        var snapshots: [String: URL] = [:]
        for token in tokens {
            guard let appURL = caskIconPaths[token] else { continue }
            let dest = base.appendingPathComponent("\(token).app")
            if (try? BundleSnapshot.clone(appURL, to: dest)) != nil { snapshots[token] = dest }
        }
        return snapshots
    }

    /// FEAT-05 canary (Gatekeeper) — on failure restore the clone (auto-rollback).
    /// FEAT-04 — on success record the publisher Team ID; alert if it changed.
    private func postCaskUpgrade(_ tokens: [String], snapshots: [String: URL]) async {
        for token in tokens {
            guard let appURL = caskIconPaths[token] else { continue }
            let healthy = await Task.detached { CanaryCheck.passesGatekeeper(appAt: appURL) }.value
            if !healthy, let snapshot = snapshots[token] {
                var restored = false
                do {
                    try BundleSnapshot.restore(snapshot: snapshot, to: appURL)
                    restored = true
                } catch {
                    // FEAT-05: lokalizacja chroniona (brak prawa zapisu) → przez root-helpera.
                    if PrivilegedHelperClient.shared.isEnabled {
                        do {
                            try await PrivilegedHelperClient.shared.replaceBundle(at: appURL.path, withSnapshotAt: snapshot.path)
                            restored = true
                        } catch {
                            AppLogger.app.error("Rollback przez helper nie powiódł się: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
                if restored {
                    brewLog.append("⚠️ " + trf("%@: nowa wersja nie przeszła kontroli — przywrócono poprzednią.", "\(token)"))
                    onWegaState?(WegaState(pose: .alert, line: trf("Cofnęłam %@ — nowa wersja nie przeszła kontroli.", "\(token)")))
                } else {
                    brewLog.append("⚠️ " + trf("%@: nowa wersja nie przeszła kontroli, ale rollback się nie powiódł.", "\(token)"))
                }
            } else {
                let teamID = await Task.detached { CodeSignatureVerifier.teamID(ofAppAt: appURL) }.value
                if case let .changed(old, new) = TeamIDLedger.shared.record(bundleID: "cask:\(token)", teamID: teamID) {
                    banner = BannerData(variant: .danger, title: tr("Zmiana wydawcy"),
                                        message: trf("%@: Team ID zmienił się (%@ → %@). Zweryfikuj.", "\(token)", "\(old)", "\(new ?? "—")"))
                }
            }
            if let snapshot = snapshots[token] { try? FileManager.default.removeItem(at: snapshot) }
        }
    }

    private func isProcessRunning(_ name: String) async -> Bool {
        await processes.isRunning(name)
    }

    private func restartApp(_ info: RestartInfo) async {
        restartBusy = info.processName
        await processes.kill(info.processName)
        try? await Task.sleep(for: .milliseconds(800))
        await processes.launch(appName: info.appName)
        restartCandidates.removeAll { $0.processName == info.processName }
        restartBusy = nil
    }
}
