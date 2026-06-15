import SwiftUI
import MacUpdaterCore

private enum UpdateStatus { case ready, checking, results }


struct UpdateView: View {
    var onWegaState:   ((WegaState) -> Void)?
    var onBadgeChange: ((Int) -> Void)?
    var onNavigate:    ((SidebarTab) -> Void)?
    var onErrorCount:  ((Int) -> Void)?

    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var policies: UpdatePolicyStore

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
                        }
                    },
                    onClose: { banner = nil }
                )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if allItems.isEmpty && visibleManual.isEmpty && restartCandidates.isEmpty {
                EmptyHero(pose: .sleep, title: tr("Wszystko aktualne"), message: tr("Wega się zdrzemnie. Zajrzymy znowu za jakiś czas."), compact: true)
            } else {
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
                        if !formulae.isEmpty { UpdateSection(title: tr("Homebrew Formulae"), subtitle: tr("narzędzia CLI"),  icon: "terminal",  items: formulae, selected: $selected, onIgnore: ignoreItem, onPin: requestPin) }
                        if !casks.isEmpty {
                            UpdateSection(title: tr("Homebrew Casks"), subtitle: tr("aplikacje .app"), icon: "app.gift", items: casks, iconPaths: caskIconPaths, selected: $selected, onIgnore: ignoreItem, onPin: requestPin)
                            caskTransparencyNote(casks: casks)
                        }
                        if !store.isEmpty    { UpdateSection(title: tr("Mac App Store"),     subtitle: tr("via mas-cli"),      icon: "bag",      items: store,    selected: $selected, onIgnore: ignoreItem, onPin: requestPin) }
                        if !npmPkgs.isEmpty  { UpdateSection(title: tr("npm globalne"),      subtitle: tr("pakiety -g"),       icon: "shippingbox", items: npmPkgs, selected: $selected, onIgnore: ignoreItem, onPin: requestPin) }
                        if !visibleManual.isEmpty {
                            ManualUpdateSection(
                                items: visibleManual,
                                busyToken: manualBusy,
                                onInstall: { token in Task { await installManual(token: token) } },
                                title: tr("Ręcznie zainstalowane"),
                                icon: "sparkle",
                                onIgnore: ignoreManual,
                                onPin: requestPinManual
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

    // MARK: Async actions
    private func runCheck() async {
        status = .checking
        errorMessage = nil
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

        do { brewOutdated = try await model.brewService.outdatedGreedy() }
        catch { errorMessage = error.localizedDescription; brewOutdated = nil; failedSources += 1
                WegaLog.error(.homebrew, "brew outdated: \(error.localizedDescription)") }

        do { masOutdated = try await model.masService.outdated() }
        catch MasServiceError.masNotFound { masOutdated = [] }
        catch { masOutdated = []; failedSources += 1
                WegaLog.error(.app, "mas outdated: \(error.localizedDescription)") }

        do { npmOutdated = try await model.npmService.outdated() }
        catch NpmServiceError.npmNotFound { npmOutdated = [] }
        catch { npmOutdated = []; failedSources += 1
                WegaLog.error(.network, "npm outdated: \(error.localizedDescription)") }

        let brewOutdatedCasks = Set(brewOutdated?.casks.map(\.name) ?? [])
        let scan = await scanManualUpdates(brewOutdatedCasks: brewOutdatedCasks)
        manualOutdated = scan.apps
        failedSources += scan.failedChecks

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

        let total = allItems.count + visibleManual.count
        WegaLog.info(.scanner, "Skan zakończony: \(total) aktualizacji, \(failedSources) źródeł nie odpowiedziało")
        switch UpdatePlanner.scanState(updateCount: total, failedChecks: failedSources) {
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
    }

    private func scanManualUpdates(brewOutdatedCasks: Set<String> = []) async -> (apps: [ManualOutdatedApp], failedChecks: Int) {
        await ManualUpdateScanner(brewService: model.brewService).scan(brewOutdatedCasks: brewOutdatedCasks)
    }

    private func installManual(token: String) async {
        guard manualBusy == nil else { return }
        manualBusy = token
        brewLog = ["$ brew install --cask \(token)"]
        showLog = true
        onWegaState?(WegaState(pose: .sniff, line: trf("Instaluję %@ przez Brew…", "\(token)")))

        do {
            let stream = try model.brewService.events(arguments: ["install", "--cask", token])
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
                onWegaState?(WegaState(pose: .happy, line: trf("%@ zaktualizowany i pod opieką Brew.", "\(token)")))
                WegaLog.info(.homebrew, "Zainstalowano \(token) (brew cask)")
            } else {
                banner = BannerData(variant: .danger, title: trf("Błąd instalacji %@", "\(token)"), message: tr("Sprawdź logi poniżej."))
                onWegaState?(WegaState(pose: .idle, line: trf("Coś poszło nie tak z %@.", "\(token)")))
                WegaLog.error(.homebrew, "Instalacja \(token) nieudana (kod \(exitCode))")
            }
        } catch {
            brewLog.append("error: \(error.localizedDescription)")
            banner = BannerData(variant: .danger, title: tr("Błąd instalacji"), message: error.localizedDescription)
            onWegaState?(WegaState(pose: .idle, line: trf("Coś poszło nie tak z %@.", "\(token)")))
            WegaLog.error(.homebrew, "Instalacja \(token): \(error.localizedDescription)")
        }
        manualBusy = nil
    }

    private func runUpdate() async {
        updating = true
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
            outcomes.append(await runBrewUpgrade(arguments: args))
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
        await runCheck()

        updating = false

        let summary = UpdatePlanner.summarize(outcomes: outcomes)
        let failedTokens = summary.failedTokens
        let needsSudoPassword = summary.needsSudoPassword
        if summary.anyFailure {
            let baseDetail = failedTokens.isEmpty
                ? tr("Brew zgłosił błąd — sprawdź log poniżej.")
                : trf("Nie udało się: %@. Szczegóły w logu.", "\(failedTokens.joined(separator: ", "))")
            let detail = needsSudoPassword
                ? trf("%@ Cask wymaga hasła administratora — uruchom Wega ponownie, helper askpass zapyta o nie w okienku.", "\(baseDetail)")
                : baseDetail
            banner = BannerData(variant: .danger, title: tr("Aktualizacja niekompletna"), message: detail)
            onWegaState?(WegaState(pose: .alert, line: tr("Część pakietów się nie zaktualizowała.")))
            WegaLog.error(.homebrew, "Aktualizacja niekompletna: \(failedTokens.isEmpty ? "Brew zgłosił błąd" : failedTokens.joined(separator: ", "))")
        } else {
            banner = BannerData(variant: .success, title: trf("Zaktualizowano %@ pakietów", "\(n)"), message: tr("Wszystko gotowe."))
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

// MARK: - Supporting types

private struct UpdateSection: View {
    let title:     String
    let subtitle:  String
    let icon:      String
    let items:     [OutdatedItem]
    var iconPaths: [String: URL]  = [:]
    @Binding var selected: Set<String>
    var onIgnore: ((OutdatedItem) -> Void)?
    var onPin:    ((OutdatedItem) -> Void)?

    var body: some View {
        WegaCard {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Color.wegaHoney)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(items.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }

            ForEach(items) { item in
                PackageRow(
                    name:           item.name,
                    iconPath:       iconPaths[item.name],
                    currentVersion: item.from,
                    latestVersion:  item.to,
                    isSelected:     selected.contains(item.key),
                    onToggle:       { toggle(item.key) }
                )
                .contextMenu {
                    UpdatePolicyMenu(onIgnore: { onIgnore?(item) }, onPin: { onPin?(item) })
                }
                .overlay(alignment: .bottom) {
                    if item.id != items.last?.id { Divider().opacity(0.4).padding(.leading, 54) }
                }
            }
        }
    }

    private func toggle(_ key: String) {
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }
}

/// Shared context-menu content for ignoring or pinning an update.
private struct UpdatePolicyMenu: View {
    let onIgnore: () -> Void
    let onPin:    () -> Void

    var body: some View {
        Button(action: onIgnore) {
            Label(tr("Nie aktualizuj"), systemImage: "bell.slash")
        }
        Button(action: onPin) {
            Label(tr("Przypnij wersję…"), systemImage: "pin")
        }
    }
}

struct PinRequest: Identifiable {
    let key:              String
    let name:             String
    let suggestedVersion: String
    var id: String { key }
}

private struct PinVersionSheet: View {
    let request:   PinRequest
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var version: String

    init(request: PinRequest, onConfirm: @escaping (String) -> Void) {
        self.request = request
        self.onConfirm = onConfirm
        _version = State(initialValue: request.suggestedVersion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Przypnij wersję")).font(.system(size: 16, weight: .bold))
                Text(request.name).font(.system(size: 13)).foregroundStyle(.secondary)
            }

            Text(tr("Wega nie pokaże aktualizacji nowszych niż podana wersja. Zostaw bieżącą, żeby zatrzymać aplikację tu, gdzie jest."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(tr("Wersja"), text: $version)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))

            HStack {
                Spacer()
                Button(tr("Anuluj")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Przypnij")) {
                    onConfirm(version)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
                .disabled(version.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

private struct ManualUpdateSection: View {
    let items:     [ManualOutdatedApp]
    let busyToken: String?
    let onInstall: (String) -> Void
    let title:     String
    let icon:      String
    var subtitle:  String? = nil
    var onIgnore:  ((ManualOutdatedApp) -> Void)?
    var onPin:     ((ManualOutdatedApp) -> Void)?

    var body: some View {
        WegaCard {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Color.wegaHoney)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(items.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }

            ForEach(items, id: \.path) { item in
                HStack(spacing: 12) {
                    AppIcon(path: item.path, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 13, weight: .medium))
                        HStack(spacing: 6) {
                            Text(item.installedVersion ?? "—")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(item.availableVersion ?? "—")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.wegaHoney)
                        }
                        // FEAT-06: doradczy badge z triage notatek wydania (np. GitHub).
                        if let notes = item.releaseNotes, ReleaseNotesTriage.heuristic(notes).isLikelySecurityFix {
                            Label(tr("możliwa poprawka bezpieczeństwa"), systemImage: "shield.lefthalf.filled")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.wegaDanger)
                        }
                    }
                    Spacer()
                    manualAction(for: item)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .contextMenu {
                    UpdatePolicyMenu(onIgnore: { onIgnore?(item) }, onPin: { onPin?(item) })
                }
                .overlay(alignment: .bottom) {
                    if item.path != items.last?.path { Divider().opacity(0.4).padding(.leading, 54) }
                }
            }
        }
    }

    @ViewBuilder
    private func manualAction(for item: ManualOutdatedApp) -> some View {
        switch item.source {
        case .sparkle:
            HStack(spacing: 8) {
                WegaBadge(label: "Sparkle", variant: .manual)
                Button {
                    // Sparkle apps own the update flow. Opening the app brings it to the
                    // foreground and (for apps with SUEnableAutomaticChecks=1, e.g. Codex)
                    // triggers the appcast check on launch — the user then accepts in the
                    // app's own update prompt. We can't drive that prompt from outside
                    // without an AppleScript that depends on each app's menu wording.
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
        case .cask(let token):
            HStack(spacing: 8) {
                WegaBadge(label: token, variant: .brew)
                Button {
                    onInstall(token)
                } label: {
                    if busyToken == token {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(tr("Zainstaluj przez Brew"), systemImage: "arrow.down.circle")
                    }
                }
                .controlSize(.small)
                .disabled(busyToken != nil)
            }
        case .mas(let appStoreID):
            HStack(spacing: 8) {
                WegaBadge(label: appStoreID, variant: .appStore)
                Text(tr("zaktualizuj w App Store"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        case .github(let repo):
            HStack(spacing: 8) {
                WegaBadge(label: "GitHub", variant: .info)
                Button {
                    if let url = AppEndpoints.shared.githubReleasesPageURL(repo: repo) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(tr("GitHub Releases"), systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
        case .jetbrains(let caskToken):
            HStack(spacing: 8) {
                WegaBadge(label: caskToken, variant: .brew)
                Button {
                    let toolboxPaths = [
                        SystemPaths.applicationsDirectory.appendingPathComponent("JetBrains Toolbox.app").path,
                        FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Applications/JetBrains Toolbox.app").path
                    ]
                    if let path = toolboxPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                } label: {
                    Label(tr("Otwórz Toolbox"), systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
            }
        case .synology(let downloadPage):
            HStack(spacing: 8) {
                WegaBadge(label: "Synology", variant: .info)
                Button {
                    if let url = URL(string: downloadPage) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(tr("Pobierz ze strony Synology"), systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
        case .antigravity:
            HStack(spacing: 8) {
                WegaBadge(label: "Antigravity", variant: .info)
                Button {
                    // Antigravity owns its own update flow (supportsFastUpdate).
                    // Launching it triggers the in-app updater — we must never
                    // route this through `brew install`, because the Homebrew
                    // cask is frozen at an older version and would downgrade it.
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
        case .parallels:
            HStack(spacing: 8) {
                WegaBadge(label: "Parallels", variant: .info)
                Button {
                    // Parallels self-updates via its bundled updater; brew cask
                    // `parallels` lags upstream and would route through a stale
                    // installer.
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
        case .googleDrive:
            HStack(spacing: 8) {
                WegaBadge(label: "Google Drive", variant: .info)
                Button {
                    NSWorkspace.shared.open(AppEndpoints.shared.googleDriveDownloadURL)
                } label: {
                    Label(tr("Pobierz najnowszą wersję"), systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
        case .chatgpt:
            HStack(spacing: 8) {
                WegaBadge(label: "ChatGPT", variant: .info)
                Button {
                    // ChatGPT self-updates via Sparkle from a runtime-resolved
                    // feed; the brew cask `chatgpt` is `auto_updates` and lags.
                    // Launching the app triggers its own update flow — never
                    // route through brew, which would reinstall a stale build.
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
        }
    }
}
