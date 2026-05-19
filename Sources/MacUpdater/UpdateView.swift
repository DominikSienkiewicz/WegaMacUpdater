import SwiftUI
import MacUpdaterCore

private enum UpdateStatus { case ready, checking, results }


struct UpdateView: View {
    var onWegaState:   ((WegaState) -> Void)?
    var onBadgeChange: ((Int) -> Void)?

    @EnvironmentObject private var model: AppViewModel

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

    // Unique keys: "f:<name>", "c:<name>", "a:<id>", "n:<name>"
    private var allItems: [OutdatedItem] {
        var items: [OutdatedItem] = []
        if let b = brewOutdated {
            items += b.formulae.map { OutdatedItem(key: "f:\($0.name)", name: $0.name, from: $0.installedVersions.first, to: $0.currentVersion, kind: .formula) }
            items += b.casks.map    { OutdatedItem(key: "c:\($0.name)", name: $0.name, from: $0.installedVersions.first, to: $0.currentVersion, kind: .cask)    }
        }
        items += masOutdated.map { OutdatedItem(key: "a:\($0.appStoreID)", name: $0.name, from: $0.installedVersion, to: $0.currentVersion, kind: .appStore) }
        items += npmOutdated.map { OutdatedItem(key: "n:\($0.name)", name: $0.name, from: $0.installedVersion, to: $0.latestVersion, kind: .npm) }
        return items
    }

    var body: some View {
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
            title: "Sprawdźmy, co się zestarzało",
            message: "Wega zajrzy do Homebrew oraz Mac App Store i powie, co warto odświeżyć.",
            action: AnyView(
                Button { Task { await runCheck() } } label: {
                    Label("Sprawdź aktualizacje", systemImage: "arrow.triangle.2.circlepath")
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
            HStack(spacing: 16) {
                Spacer()
                WegaFull(pose: .sniff, size: 120)
                Text("Wega węszy po Homebrew…")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(.secondary)
                Spacer()
            }
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
                    Text(allItems.isEmpty ? "Wszystko aktualne" : "\(allItems.count) aktualizacji do zainstalowania")
                        .font(.system(size: 18, weight: .semibold))
                    if let d = lastCheck {
                        HStack(spacing: 4) {
                            Text("Sprawdzono \(d.formatted(date: .omitted, time: .shortened))")
                            Text("·")
                            Text("brew + mas").font(.system(size: 11, design: .monospaced))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button { Task { await runCheck() } } label: {
                    Label("Sprawdź ponownie", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(updating || status == .checking)

                if !allItems.isEmpty {
                    Button { Task { await runUpdate() } } label: {
                        if updating {
                            ProgressView().controlSize(.small)
                        } else if selected.isEmpty {
                            Label("Zaktualizuj wszystkie (\(allItems.count))", systemImage: "arrow.down.circle.fill")
                        } else {
                            Label("Zaktualizuj wybrane (\(selected.count))", systemImage: "arrow.down.circle.fill")
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
                BannerView(data: b) { banner = nil }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if allItems.isEmpty && manualOutdated.isEmpty && restartCandidates.isEmpty {
                EmptyHero(pose: .sleep, title: "Wszystko aktualne", message: "Wega się zdrzemnie. Zajrzymy znowu za jakiś czas.", compact: true)
            } else {
                // Select-all row
                HStack(spacing: 10) {
                    Image(systemName: selectAllSymbol)
                        .foregroundStyle(selected.isEmpty ? .secondary : Color.wegaHoney)
                        .font(.system(size: 16))
                        .onTapGesture { toggleAll() }
                    Text(selected.isEmpty ? "Zaznacz wszystko" : "\(selected.count) z \(allItems.count) zaznaczonych")
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
                        if !formulae.isEmpty { UpdateSection(title: "Homebrew Formulae", subtitle: "narzędzia CLI",  icon: "terminal",  items: formulae, selected: $selected) }
                        if !casks.isEmpty    { UpdateSection(title: "Homebrew Casks",    subtitle: "aplikacje .app", icon: "app.gift", items: casks,    iconPaths: caskIconPaths, selected: $selected) }
                        if !store.isEmpty    { UpdateSection(title: "Mac App Store",     subtitle: "via mas-cli",      icon: "bag",      items: store,    selected: $selected) }
                        if !npmPkgs.isEmpty  { UpdateSection(title: "npm globalne",      subtitle: "pakiety -g",       icon: "shippingbox", items: npmPkgs, selected: $selected) }
                        if !manualOutdated.isEmpty {
                            ManualUpdateSection(
                                items: manualOutdated,
                                busyToken: manualBusy,
                                onInstall: { token in Task { await installManual(token: token) } }
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
        if selected.isEmpty { return "square" }
        if selected.count == allItems.count { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private func toggleAll() {
        if selected.count == allItems.count { selected.removeAll() }
        else { selected = Set(allItems.map(\.key)) }
    }

    // MARK: Async actions
    private func runCheck() async {
        status = .checking
        errorMessage = nil
        onWegaState?(WegaState(pose: .sniff, line: "Węszę po Homebrew…"))

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

        do { brewOutdated = try await model.brewService.outdatedGreedy() }
        catch { errorMessage = error.localizedDescription; brewOutdated = nil }

        do { masOutdated = try await model.masService.outdated() }
        catch MasServiceError.masNotFound { masOutdated = [] }
        catch { masOutdated = [] }

        do { npmOutdated = try await model.npmService.outdated() }
        catch NpmServiceError.npmNotFound { npmOutdated = [] }
        catch { npmOutdated = [] }

        let brewOutdatedCasks = Set(brewOutdated?.casks.map(\.name) ?? [])
        manualOutdated = await scanManualUpdates(brewOutdatedCasks: brewOutdatedCasks)

        // Resolve icon paths for outdated casks
        if let casks = brewOutdated?.casks, !casks.isEmpty {
            let infos = (try? await model.brewService.caskInstallationInfo(tokens: casks.map(\.name))) ?? []
            let home = FileManager.default.homeDirectoryForCurrentUser
            var paths: [String: URL] = [:]
            for info in infos {
                for artifact in info.appArtifacts {
                    let system = URL(fileURLWithPath: "/Applications/\(artifact)")
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

        lastCheck = Date()
        status    = .results
        if let msg = errorMessage {
            banner = BannerData(variant: .danger, title: "Błąd Homebrew", message: msg)
        }
        let total = allItems.count + manualOutdated.count
        onWegaState?(total == 0
            ? WegaState(pose: .happy, line: "Wszystko aktualne. Idę się zdrzemnąć.")
            : WegaState(pose: .alert, line: "Znalazłam \(total) rzeczy do uporządkowania."))
        onBadgeChange?(allItems.count)
    }

    private func scanManualUpdates(brewOutdatedCasks: Set<String> = []) async -> [ManualOutdatedApp] {
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(AppMetadata.bundleIdentifier)/casks.json")
        let casks = (try? await CaskDatabaseClient(cache: CaskDatabaseCache(fileURL: cacheURL)).fetchCasks()) ?? []
        let installedCasks = (try? await model.brewService.installedCasks()) ?? []
        // brew-tracked versions (from `brew list --cask --versions`); used as ground truth
        // for brew-managed apps instead of bundle version to avoid versioning scheme mismatches.
        let brewCaskVersions = (try? await model.brewService.caskVersions()) ?? [:]

        // Drop CLI-only casks (e.g. `codex`) from the set we feed to CaskMatcher.
        // Otherwise an unrelated /Applications/Codex.app gets misclassified as brew-managed.
        let installInfo = (try? await model.brewService.caskInstallationInfo(tokens: Array(installedCasks))) ?? []
        let appProducingTokens: Set<String> = {
            let producers = Set(installInfo.filter { !$0.appArtifacts.isEmpty }.map(\.token))
            // If brew info failed for everything (offline?), don't accidentally hide all matches.
            return producers.isEmpty ? installedCasks : producers
        }()

        let scanner = ApplicationScanner()
        var seen = Set<String>()
        var appsToCheck: [ApplicationInfo] = []
        for dir in buildScanDirs() {
            let found = (try? scanner.scanApplications(in: dir, installedCasks: appProducingTokens, availableCasks: casks)) ?? []
            for app in found where !app.isManagedByMas {
                if let token = app.caskToken, brewOutdatedCasks.contains(token) { continue }
                let key = app.bundleIdentifier ?? app.path.path
                if seen.insert(key).inserted { appsToCheck.append(app) }
            }
        }

        let sparkleChecker = SparkleUpdateChecker()
        let jetbrainsChecker = JetBrainsUpdateChecker()
        let githubChecker = GitHubReleasesChecker()
        let synologyChecker = SynologyUpdateChecker()
        var byPath: [String: ManualOutdatedApp] = [:]

        await withTaskGroup(of: ManualOutdatedApp?.self) { group in
            for app in appsToCheck {
                if let token = app.caskToken {
                    let brewTracked = brewCaskVersions[token]
                    group.addTask {
                        guard let latest = await self.model.brewService.caskLatestVersion(token: token) else { return nil }
                        let reference = brewTracked ?? app.version
                        guard let installed = reference,
                              !versionsEqual(latest, installed),
                              isUpgrade(installed: installed, latest: latest) else { return nil }
                        return ManualOutdatedApp(
                            name: app.name, path: app.path,
                            installedVersion: app.version ?? installed,
                            availableVersion: versionVariants(latest).first ?? latest,
                            source: .cask(token: token)
                        )
                    }
                }
                group.addTask { await jetbrainsChecker.check(app: app) }
                group.addTask { await githubChecker.check(app: app) }
                group.addTask { await synologyChecker.check(app: app) }
                // Always run Sparkle: even when an app is matched to an installed cask
                // (e.g. Codex.app vs. cask `codex` which is actually a CLI binary), the
                // app itself may have its own appcast. Priority dedup in `byPath`
                // ensures cask (2) wins over sparkle (1) when both report the same path.
                group.addTask { await sparkleChecker.check(app: app) }
            }
            for await item in group {
                guard let item else { continue }
                let key = item.path.path
                if let existing = byPath[key] {
                    if item.source.priority > existing.source.priority { byPath[key] = item }
                } else {
                    byPath[key] = item
                }
            }
        }
        return byPath.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func installManual(token: String) async {
        guard manualBusy == nil else { return }
        manualBusy = token
        brewLog = ["$ brew install --cask \(token)"]
        showLog = true
        onWegaState?(WegaState(pose: .sniff, line: "Instaluję \(token) przez Brew…"))

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
                banner = BannerData(variant: .success, title: "Zaktualizowano \(token)", message: "Teraz zarządzany przez Homebrew.")
                onWegaState?(WegaState(pose: .happy, line: "\(token) zaktualizowany i pod opieką Brew."))
            } else {
                banner = BannerData(variant: .danger, title: "Błąd instalacji \(token)", message: "Sprawdź logi poniżej.")
                onWegaState?(WegaState(pose: .idle, line: "Coś poszło nie tak z \(token)."))
            }
        } catch {
            brewLog.append("error: \(error.localizedDescription)")
            banner = BannerData(variant: .danger, title: "Błąd instalacji", message: error.localizedDescription)
            onWegaState?(WegaState(pose: .idle, line: "Coś poszło nie tak z \(token)."))
        }
        manualBusy = nil
    }

    private func runUpdate() async {
        updating = true
        brewLog = []
        showLog = true
        onWegaState?(WegaState(pose: .sniff, line: "Aktualizuję, chwila…"))

        let itemsToUpdate = selected.isEmpty ? Set(allItems.map(\.key)) : selected
        let formulaNames  = itemsToUpdate.compactMap { $0.hasPrefix("f:") ? String($0.dropFirst(2)) : nil }
        let caskNames     = itemsToUpdate.compactMap { $0.hasPrefix("c:") ? String($0.dropFirst(2)) : nil }
        let npmNames      = itemsToUpdate.compactMap { $0.hasPrefix("n:") ? String($0.dropFirst(2)) : nil }
        let hasMasItems   = itemsToUpdate.contains { $0.hasPrefix("a:") }
        let n             = itemsToUpdate.count

        // Pre-capture which casks being updated are currently running
        var candidates: [RestartInfo] = []
        for token in caskNames {
            if let info = MacUpdaterConstants.restartMap[token], await isProcessRunning(info.processName) {
                candidates.append(info)
            }
        }

        var outcomes: [BrewUpgradeOutcome] = []

        // Brew upgrade — formulae
        if !formulaNames.isEmpty {
            let args = ["upgrade"] + formulaNames
            outcomes.append(await runBrewUpgrade(arguments: args))
        }

        // Brew upgrade — casks
        if !caskNames.isEmpty {
            let args = ["upgrade", "--cask"] + caskNames
            outcomes.append(await runBrewUpgrade(arguments: args))
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
            }
        }

        _ = try? await model.brewService.cleanup()

        selected.removeAll()
        restartCandidates = candidates

        // Re-query brew/mas so the list reflects reality, not optimistic clearing.
        // If a cask failed (e.g. "App source not there"), it will still appear here.
        await runCheck()

        updating = false

        let failedTokens = outcomes.flatMap(\.failedTokens)
        let anyFailure = outcomes.contains { !$0.isSuccessful }
        let needsSudoPassword = outcomes.contains { $0.requiresSudoPassword }
        if anyFailure {
            let baseDetail = failedTokens.isEmpty
                ? "Brew zgłosił błąd — sprawdź log poniżej."
                : "Nie udało się: \(failedTokens.joined(separator: ", ")). Szczegóły w logu."
            let detail = needsSudoPassword
                ? "\(baseDetail) Cask wymaga hasła administratora — uruchom Wega ponownie, helper askpass zapyta o nie w okienku."
                : baseDetail
            banner = BannerData(variant: .danger, title: "Aktualizacja niekompletna", message: detail)
            onWegaState?(WegaState(pose: .alert, line: "Część pakietów się nie zaktualizowała."))
        } else {
            banner = BannerData(variant: .success, title: "Zaktualizowano \(n) pakietów", message: "Wszystko gotowe.")
            onWegaState?(WegaState(pose: .happy, line: "Gotowe! \(n) pakietów odświeżonych."))
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

    private func isProcessRunning(_ name: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                p.arguments = ["-x", name]
                try? p.run()
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }

    private func restartApp(_ info: RestartInfo) async {
        restartBusy = info.processName
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                p.arguments = [info.processName]
                try? p.run()
                p.waitUntilExit()
                cont.resume(returning: ())
            }
        }
        try? await Task.sleep(for: .milliseconds(800))
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-a", info.appName]
                try? p.run()
                p.waitUntilExit()
                cont.resume(returning: ())
            }
        }
        restartCandidates.removeAll { $0.processName == info.processName }
        restartBusy = nil
    }
}

// MARK: - Supporting types

private struct OutdatedItem: Identifiable {
    enum Kind { case formula, cask, appStore, npm }
    let key:  String
    var id:   String { key }
    let name: String
    let from: String?
    let to:   String?
    let kind: Kind
}

private struct UpdateSection: View {
    let title:     String
    let subtitle:  String
    let icon:      String
    let items:     [OutdatedItem]
    var iconPaths: [String: URL]  = [:]
    @Binding var selected: Set<String>

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

private struct ManualUpdateSection: View {
    let items:     [ManualOutdatedApp]
    let busyToken: String?
    let onInstall: (String) -> Void

    var body: some View {
        WegaCard {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").foregroundStyle(Color.wegaHoney)
                Text("Ręcznie zainstalowane")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(items.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
                    }
                    Spacer()
                    manualAction(for: item)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
                    Label("Otwórz i zaktualizuj", systemImage: "arrow.up.forward.app")
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
                        Label("Zainstaluj przez Brew", systemImage: "arrow.down.circle")
                    }
                }
                .controlSize(.small)
                .disabled(busyToken != nil)
            }
        case .mas(let appStoreID):
            HStack(spacing: 8) {
                WegaBadge(label: appStoreID, variant: .appStore)
                Text("zaktualizuj w App Store")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        case .github(let repo):
            HStack(spacing: 8) {
                WegaBadge(label: "GitHub", variant: .info)
                Button {
                    if let url = URL(string: "https://github.com/\(repo)/releases/latest") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("GitHub Releases", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
        case .jetbrains(let caskToken):
            HStack(spacing: 8) {
                WegaBadge(label: caskToken, variant: .brew)
                Button {
                    let toolboxPaths = [
                        "/Applications/JetBrains Toolbox.app",
                        FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Applications/JetBrains Toolbox.app").path
                    ]
                    if let path = toolboxPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                } label: {
                    Label("Otwórz Toolbox", systemImage: "arrow.down.circle")
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
                    Label("Pobierz ze strony Synology", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
        }
    }
}

private struct RestartSection: View {
    let candidates:   [RestartInfo]
    let busyProcess:  String?
    let onRestart:    (RestartInfo) -> Void

    var body: some View {
        WegaCard {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle").foregroundStyle(Color.wegaHoney)
                Text("Do restartu").font(.system(size: 13, weight: .semibold))
                Text("\(candidates.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                Text("były otwarte podczas aktualizacji").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }

            ForEach(candidates, id: \.processName) { info in
                HStack(spacing: 12) {
                    PackageLetterIcon(name: info.appName, size: 32)
                    Text(info.appName).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button { onRestart(info) } label: {
                        if busyProcess == info.processName {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Uruchom ponownie", systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.small)
                    .disabled(busyProcess != nil)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    if info.processName != candidates.last?.processName {
                        Divider().opacity(0.4).padding(.leading, 54)
                    }
                }
            }
        }
    }
}

private struct BrewLogPanel: View {
    let lines:   [String]
    let onClose: () -> Void

    var body: some View {
        WegaCard(padded: false) {
            HStack(spacing: 8) {
                Circle().fill(Color.wegaSuccess).frame(width: 6, height: 6)
                Text("brew log")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider().opacity(0.4) }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("$") ? Color.wegaHoney : Color.primary.opacity(0.75))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .frame(maxHeight: 220)
                .onChange(of: lines.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }
}

private struct CheckingBar: View {
    let command: String
    let delay:   Double

    @State private var visible = false

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(Color.wegaHoney)
            Text("$ \(command)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.wegaHoney.opacity(0.15))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [Color.wegaToffee, Color.wegaHoney], startPoint: .leading, endPoint: .trailing))
                        .frame(width: visible ? .infinity : 0)
                        .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: visible)
                }
                .frame(width: 160)
        }
        .opacity(visible ? 1 : 0)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { visible = true }
        }
    }
}
