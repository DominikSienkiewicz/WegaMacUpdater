import AppKit
import Foundation
import MacUpdaterCore

enum MigrationStatus {
    case ready
    case scanning
    case results
}

struct PendingForceTermination: Identifiable {
    let app: ApplicationInfo
    let target: RunningApplicationTarget

    var id: String { app.id }
}

/// App-owned migration state machine and its process, network and filesystem boundary.
/// It lives above the localized SwiftUI identity boundary, so changing language cannot
/// erase an in-flight migration, its consent dialog, results, or operation log.
@MainActor
final class MigrationStore: ObservableObject {
    @Published var status: MigrationStatus = .ready
    @Published var candidates: [ApplicationInfo] = []
    @Published var migrated: Set<String> = []
    @Published var migrating: String?
    @Published var confirmingApp: ApplicationInfo?
    @Published var logLines: [String] = []
    @Published var errorMessage: String?
    @Published var banner: BannerData?
    @Published var masCandidates: [(app: ApplicationInfo, masID: String)] = []
    @Published var npmBrewDuplicates: [NpmBrewDuplicate] = []
    @Published var duplicateConfirmation: DuplicateRemoval?
    @Published var duplicateBusyKey: String?
    @Published var pendingForceTermination: PendingForceTermination?

    private let processes: RunningProcessService
    private let runningApplicationInspector: any RunningApplicationInspecting
    private let runningApplicationTerminator: any RunningApplicationTargetTerminating

    init(
        processes: RunningProcessService = RunningProcessService(),
        runningApplicationInspector: any RunningApplicationInspecting =
            WorkspaceRunningApplicationInspector(),
        runningApplicationTerminator: any RunningApplicationTargetTerminating =
            WorkspaceTargetTerminator()
    ) {
        self.processes = processes
        self.runningApplicationInspector = runningApplicationInspector
        self.runningApplicationTerminator = runningApplicationTerminator
    }

    func scan(
        model: AppViewModel,
        onWegaState: (@MainActor (WegaState) -> Void)?
    ) async {
        await OperationCoordinator.shared.withRead(label: "migration scan") { @MainActor in
            await self.scanCoordinated(model: model, onWegaState: onWegaState)
        }
    }

    func migrate(
        _ app: ApplicationInfo,
        model: AppViewModel,
        onWegaState: (@MainActor (WegaState) -> Void)?
    ) async {
        guard migrating == nil, let token = app.caskToken else { return }

        // REL-08 — the match confidence must gate the takeover before anything runs. A low
        // score means `brew install --cask --force <token>` could overwrite this app with a
        // different program, so the automatic takeover is refused (the badge already warned
        // "niepewne"). This is the production call-site `allowsAutoConfirm` never had.
        let confidence = CaskMatchScorer.score(
            applicationName: app.name,
            caskToken: token,
            caskNames: [],
            viaCustomMapping: false
        )
        guard MigrationAutoTakeover.decide(confidence) != .blocked else {
            errorMessage = trf(
                "Dopasowanie %@ → %@ jest zbyt niepewne, aby przepiąć automatycznie. Zweryfikuj je ręcznie przed migracją.",
                "\(app.name)",
                "\(token)"
            )
            return
        }

        migrating = token
        errorMessage = nil
        logLines = []

        switch resolveRunningTarget(for: app) {
        case .notRunning:
            break
        case .ambiguousBundleIdentifier(let bundleIdentifier):
            migrating = nil
            errorMessage = trf(
                "Nie można jednoznacznie wskazać działającej aplikacji dla bundle ID %@. Migracja nie została uruchomiona.",
                "\(bundleIdentifier)"
            )
            return
        case .running(let target):
            logLines.append(trf("Proszę %@ o łagodne zakończenie…", "\(target.appName)"))
            let requestDelivered = runningApplicationTerminator.requestGracefulTermination(target)
            if !requestDelivered {
                logLines.append(trf(
                    "Łagodna prośba o zamknięcie %@ nie powiodła się; sprawdzam stan procesu…",
                    "\(target.appName)"
                ))
            }
            switch await waitForApplicationToStop(app) {
            case .notRunning:
                logLines.append(trf("%@ zamknięto łagodnie.", "\(target.appName)"))
            case .running(let currentTarget):
                migrating = nil
                pendingForceTermination = PendingForceTermination(app: app, target: currentTarget)
                return
            case .ambiguousBundleIdentifier(let bundleIdentifier):
                migrating = nil
                errorMessage = trf(
                    "Nie można potwierdzić zatrzymania aplikacji dla bundle ID %@. Migracja nie została uruchomiona.",
                    "\(bundleIdentifier)"
                )
                return
            }
        }

        await performMigration(app, token: token, model: model, onWegaState: onWegaState)
    }

    func forceTerminateAndMigrate(
        _ request: PendingForceTermination,
        model: AppViewModel,
        onWegaState: (@MainActor (WegaState) -> Void)?
    ) async {
        guard migrating == nil, let token = request.app.caskToken else { return }
        pendingForceTermination = nil
        migrating = token
        let currentTarget: RunningApplicationTarget
        switch resolveRunningTarget(for: request.app) {
        case .running(let target):
            currentTarget = target
        case .notRunning:
            await performMigration(
                request.app,
                token: token,
                model: model,
                onWegaState: onWegaState
            )
            return
        case .ambiguousBundleIdentifier:
            errorMessage = trf(
                "Nie można ponownie potwierdzić działającej aplikacji %@. Migracja nie została uruchomiona.",
                "\(request.app.name)"
            )
            migrating = nil
            return
        }
        logLines.append(trf("Wymuszam zamknięcie %@ za Twoją zgodą…", "\(currentTarget.appName)"))

        guard await processes.forceKill(processIdentifier: currentTarget.processIdentifier) else {
            errorMessage = trf(
                "Nie udało się wymusić zamknięcia %@. Migracja nie została uruchomiona.",
                "\(currentTarget.appName)"
            )
            migrating = nil
            return
        }
        guard case .notRunning = await waitForApplicationToStop(request.app) else {
            errorMessage = trf(
                "%@ nadal działa po próbie wymuszonego zamknięcia. Migracja nie została uruchomiona.",
                "\(currentTarget.appName)"
            )
            migrating = nil
            return
        }

        await performMigration(
            request.app,
            token: token,
            model: model,
            onWegaState: onWegaState
        )
    }

    func removeDuplicate(
        _ removal: DuplicateRemoval,
        model: AppViewModel,
        onWegaState: (@MainActor (WegaState) -> Void)?
    ) async {
        await performWrite(.duplicateRemoval) {
            await self.removeDuplicateCoordinated(
                removal,
                model: model,
                onWegaState: onWegaState
            )
        }
    }

    func openAppStore(masID: String) {
        guard let url = URL(string: "macappstore://apps.apple.com/app/id\(masID)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func scanCoordinated(
        model: AppViewModel,
        onWegaState: (@MainActor (WegaState) -> Void)?
    ) async {
        guard status != .scanning else { return }
        status = .scanning
        errorMessage = nil
        masCandidates = []
        npmBrewDuplicates = []
        onWegaState?(WegaState(
            pose: .sniff,
            line: tr("Tropię intruzów w /Applications i ~/Applications…")
        ))

        do {
            let cacheURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/\(AppMetadata.bundleIdentifier)/casks.json")
            let casks = try await CaskDatabaseClient(
                cache: CaskDatabaseCache(fileURL: cacheURL)
            ).fetchCasks()
            let installed = try await model.brewService.installedCasks()
            let npmInstalled = (try? await model.npmService.installedGlobals()) ?? []
            npmBrewDuplicates = NpmBrewDuplicateDetector().detect(
                npmPackages: npmInstalled,
                brewTokens: installed
            )
            let scanner = ApplicationScanner()
            let all = buildScanDirs().flatMap { directory in
                (try? scanner.scanApplications(
                    in: directory,
                    installedCasks: installed,
                    availableCasks: casks
                )) ?? []
            }
            let migrationPool = MigrationPlanner.migrationPool(
                InstallationInventory.deduplicated(all)
            )
            candidates = migrationPool

            let toSearch = migrationPool.filter { $0.caskToken == nil }
            if !toSearch.isEmpty {
                let masService = model.masService
                var found: [(app: ApplicationInfo, masID: String)] = []
                await withTaskGroup(of: (ApplicationInfo, String?).self) { group in
                    for app in toSearch {
                        group.addTask {
                            let id = try? await masService.search(name: app.name)
                            return (app, id)
                        }
                    }
                    for await (app, maybeID) in group {
                        if let id = maybeID { found.append((app: app, masID: id)) }
                    }
                }
                masCandidates = found
            }
        } catch {
            candidates = []
            errorMessage = error.localizedDescription
        }

        status = .results
        let brewCount = candidates.filter { $0.caskToken != nil }.count
        let total = brewCount + masCandidates.count
        onWegaState?(WegaState(
            pose: total > 0 ? .alert : .happy,
            line: total > 0
                ? trf("Zwęszyłam %@ aplikacji do przepięcia.", "\(total)")
                : tr("Wszystko porządku. Wega nie znalazła uciekinierów.")
        ))
    }

    private func performMigration(
        _ app: ApplicationInfo,
        token: String,
        model: AppViewModel,
        onWegaState: (@MainActor (WegaState) -> Void)?
    ) async {
        await performWrite(.migration) {
            await self.performMigrationCoordinated(
                app,
                token: token,
                model: model,
                onWegaState: onWegaState
            )
        }
    }

    private func performMigrationCoordinated(
        _ app: ApplicationInfo,
        token: String,
        model: AppViewModel,
        onWegaState: (@MainActor (WegaState) -> Void)?
    ) async {
        defer { migrating = nil }
        guard UpgradeMutex.shared.acquire() else {
            errorMessage = tr("Wega właśnie aktualizuje coś w tle. Spróbuj za chwilę.")
            return
        }
        defer { UpgradeMutex.shared.release() }
        let ticket = MutationGuard.shared.begin(trf("migracja %@", "\(token)"))
        defer { MutationGuard.shared.end(ticket) }
        onWegaState?(WegaState(
            pose: .sniff,
            line: trf("Instaluję %@ przez Homebrew…", "\(app.name)")
        ))

        let preparation: CaskReplacementSafety.Preparation
        switch await CaskReplacementSafety.prepare(
            token: token,
            appURL: app.path,
            brewService: model.brewService
        ) {
        case .ready(let ready):
            preparation = ready
        case .resourcePostponed(let reason):
            logLines.append("⏸ " + trf("Aktualizacja odroczona: %@.", "\(reason)"))
            errorMessage = trf("Bramka zasobów: %@.", "\(reason)")
            onWegaState?(WegaState(
                pose: .alert,
                line: tr("Warunki nie pozwalają teraz bezpiecznie pobrać aktualizacji.")
            ))
            return
        case .publisherRejected(let old, let new):
            errorMessage = trf(
                "%@: Team ID zmienił się (%@ → %@). Zweryfikuj.",
                "\(token)",
                "\(old)",
                "\(new ?? "—")"
            )
            if let errorMessage { logLines.append("⏸ " + errorMessage) }
            onWegaState?(WegaState(
                pose: .alert,
                line: tr("Zmienił się wydawca aplikacji — sprawdź.")
            ))
            return
        case .snapshotFailed:
            errorMessage = tr("Nie udało się utworzyć wymaganego snapshotu.")
            onWegaState?(WegaState(pose: .alert, line: tr("Aktualizacja odroczona")))
            return
        }

        var installError: Error?
        var exitCode: Int32 = 0
        do {
            let stream = try model.brewService.events(
                arguments: ["install", "--cask", "--force", token]
            )
            for try await event in stream {
                switch event {
                case .stdout(let line), .stderr(let line):
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        logLines.append(trimmed)
                        if logLines.count > 200 { logLines.removeFirst() }
                    }
                case .finished(let result):
                    exitCode = result.exitCode
                }
            }
        } catch {
            logLines.append("error: \(error.localizedDescription)")
            installError = error
        }

        let installedAppURL = await CaskReplacementSafety.resolveInstalledAppURL(
            preparation,
            brewService: model.brewService
        )
        let verification = await CaskReplacementSafety.verify(
            preparation,
            installedAppURL: installedAppURL
        )
        guard reportMigrationVerification(
            verification,
            app: app,
            token: token,
            onWegaState: onWegaState
        ) else { return }

        if let installError {
            errorMessage = installError.localizedDescription
            onWegaState?(WegaState(
                pose: .sad,
                line: trf("Błąd podczas migracji %@.", "\(app.name)")
            ))
        } else if exitCode == 0 {
            migrated.insert(token)
            logLines = []
            banner = BannerData(
                variant: .success,
                title: trf("%@ pod Homebrew", "\(app.name)"),
                message: trf("Token: %@", "\(token)")
            )
            onWegaState?(WegaState(
                pose: .happy,
                line: trf("%@ przejęty! Idziemy dalej.", "\(app.name)")
            ))
        } else {
            errorMessage = trf(
                "Instalacja %@ zakończyła się błędem (kod %@). Sprawdź log poniżej.",
                "\(token)",
                "\(exitCode)"
            )
            onWegaState?(WegaState(
                pose: .sad,
                line: trf("Ups. Brew zgłosił problem z %@.", "\(app.name)")
            ))
        }
    }

    private func reportMigrationVerification(
        _ verdict: CaskValidationVerdict,
        app: ApplicationInfo,
        token: String,
        onWegaState: (@MainActor (WegaState) -> Void)?
    ) -> Bool {
        switch verdict {
        case .healthy:
            return true
        case .rolledBack:
            errorMessage = trf(
                "%@: nowa wersja nie przeszła kontroli — przywrócono poprzednią.",
                "\(token)"
            )
        case .rollbackFailed:
            errorMessage = trf(
                "%@: nowa wersja nie przeszła kontroli, a przywrócenie poprzedniej nie powiodło się. Sprawdź aplikację przed użyciem.",
                "\(token)"
            )
        case .publisherChanged(let old, let new):
            errorMessage = trf(
                "%@: Team ID zmienił się (%@ → %@). Zweryfikuj.",
                "\(token)",
                "\(old)",
                "\(new ?? "—")"
            )
        case .publisherChangedAndRolledBack(let old, let new):
            errorMessage = trf(
                "%@: Team ID zmienił się (%@ → %@). Przywrócono poprzednią zaufaną wersję.",
                "\(token)",
                "\(old)",
                "\(new ?? "—")"
            )
        }
        if let errorMessage { logLines.append("⚠️ " + errorMessage) }
        onWegaState?(WegaState(
            pose: .alert,
            line: trf("Błąd podczas migracji %@.", "\(app.name)")
        ))
        return false
    }

    private func resolveRunningTarget(for app: ApplicationInfo) -> RunningApplicationResolution {
        MigrationRunningApplicationResolver.resolve(
            app: app,
            running: runningApplicationInspector.runningApplications()
        )
    }

    private func waitForApplicationToStop(
        _ app: ApplicationInfo
    ) async -> RunningApplicationResolution {
        for _ in 0..<10 {
            let resolution = resolveRunningTarget(for: app)
            if case .notRunning = resolution { return resolution }
            if case .ambiguousBundleIdentifier = resolution { return resolution }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return resolveRunningTarget(for: app)
    }

    private func removeDuplicateCoordinated(
        _ removal: DuplicateRemoval,
        model: AppViewModel,
        onWegaState: (@MainActor (WegaState) -> Void)?
    ) async {
        let key = removal.busyKey
        guard duplicateBusyKey == nil else { return }
        let ticket = MutationGuard.shared.begin(trf("usuwanie duplikatu %@", "\(key)"))
        defer { MutationGuard.shared.end(ticket) }
        duplicateBusyKey = key
        logLines = []

        let title: String
        let stream: AsyncThrowingStream<ProcessOutputEvent, Error>
        do {
            switch removal.side {
            case .npm:
                title = "$ npm uninstall -g \(removal.dup.npmPackage)"
                stream = try model.npmService.uninstallEvents(name: removal.dup.npmPackage)
            case .brew:
                title = "$ brew uninstall \(removal.dup.brewToken)"
                stream = try model.brewService.events(
                    arguments: ["uninstall", removal.dup.brewToken]
                )
            }
        } catch {
            banner = BannerData(
                variant: .danger,
                title: tr("Nie udało się uruchomić"),
                message: error.localizedDescription
            )
            duplicateBusyKey = nil
            return
        }
        logLines.append(title)

        var exitCode: Int32 = 0
        do {
            for try await event in stream {
                switch event {
                case .stdout(let chunk), .stderr(let chunk):
                    for line in chunk.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { logLines.append(trimmed) }
                    }
                    if logLines.count > 200 {
                        logLines.removeFirst(logLines.count - 200)
                    }
                case .finished(let result):
                    exitCode = result.exitCode
                }
            }
        } catch {
            logLines.append("error: \(error.localizedDescription)")
            exitCode = -1
        }

        if exitCode == 0 {
            npmBrewDuplicates.removeAll { $0.npmPackage == removal.dup.npmPackage }
            let label = removal.side == .npm ? "npm" : "brew"
            banner = BannerData(
                variant: .success,
                title: trf("Usunięto z %@", "\(label)"),
                message: removal.side == .npm
                    ? removal.dup.npmPackage
                    : removal.dup.brewToken
            )
            onWegaState?(WegaState(
                pose: .happy,
                line: tr("Duplikat zniknął. PATH ma już tylko jedną wersję.")
            ))
        } else {
            banner = BannerData(
                variant: .danger,
                title: tr("Nie udało się usunąć duplikatu"),
                message: tr("Szczegóły w logu poniżej.")
            )
        }
        duplicateBusyKey = nil
    }

    private func performWrite(
        _ flow: UpgradeCoordinator.Flow,
        operation: @MainActor @Sendable () async -> Void
    ) async {
        await UpgradeCoordinator.shared.performWrite(flow, operation: operation)
    }
}
