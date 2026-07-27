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
    /// LT-03 — publisher corroboration per candidate, computed once per scan (see
    /// `publisherCorrelations(for:using:)`) so the confidence badge can consult the
    /// strongest signal without any view doing I/O.
    @Published private(set) var publisherCorrelations: [String: CaskPublisherCorrelation] = [:]

    private let processes: RunningProcessService
    private let runningApplicationInspector: any RunningApplicationInspecting
    private let runningApplicationTerminator: any RunningApplicationTargetTerminating
    private let publisherCorrelator: CaskPublisherCorrelator

    init(
        processes: RunningProcessService = RunningProcessService(),
        runningApplicationInspector: any RunningApplicationInspecting =
            WorkspaceRunningApplicationInspector(),
        runningApplicationTerminator: any RunningApplicationTargetTerminating =
            WorkspaceTargetTerminator(),
        publisherCorrelator: CaskPublisherCorrelator = .live
    ) {
        self.processes = processes
        self.runningApplicationInspector = runningApplicationInspector
        self.runningApplicationTerminator = runningApplicationTerminator
        self.publisherCorrelator = publisherCorrelator
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
        // Claimed before the first suspension point so two overlapping requests cannot both
        // pass the guard while the publisher correlation is being measured.
        migrating = token
        errorMessage = nil
        logLines = []

        // LT-03 — the strongest signal the scorer knows, finally supplied. `TeamIDLedger`
        // already records which publisher signs each cask; correlating it with the installed
        // bundle's Developer ID turns "the names look alike" into evidence, and turns a
        // publisher mismatch into a hard `.low`. Measured for this one app rather than read
        // from the scan cache: it gates an in-place `--force` overwrite, and one signature
        // read is nothing beside the install it guards. It runs off the MainActor.
        let correlation = await Self.publisherCorrelation(
            for: app,
            token: token,
            using: publisherCorrelator
        )

        // REL-08 — the match confidence must gate the takeover before anything runs. A low
        // score means `brew install --cask --force <token>` could overwrite this app with a
        // different program, so the automatic takeover is refused (the badge already warned
        // "niepewne"). This is the production call-site `allowsAutoConfirm` never had.
        let confidence = CaskMatchScorer.score(
            applicationName: app.name,
            caskToken: token,
            caskNames: [],
            viaCustomMapping: false,
            installedAppTeamID: correlation.installedAppTeamID,
            caskExpectedTeamID: correlation.caskExpectedTeamID
        )
        guard MigrationAutoTakeover.decide(confidence) != .blocked else {
            migrating = nil
            errorMessage = correlation.isPublisherMismatch
                ? trf(
                    "Zainstalowana aplikacja %@ jest podpisana przez innego wydawcę (%@) niż wydawca znany dla caska %@ (%@). Wega nie przepnie jej automatycznie.",
                    "\(app.name)",
                    "\(correlation.installedAppTeamID ?? "—")",
                    "\(token)",
                    "\(correlation.caskExpectedTeamID ?? "—")"
                )
                : trf(
                    "Dopasowanie %@ → %@ jest zbyt niepewne, aby przepiąć automatycznie. Zweryfikuj je ręcznie przed migracją.",
                    "\(app.name)",
                    "\(token)"
                )
            return
        }

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
            line: tr("Tropię intruzów w Twoich katalogach aplikacji…")
        ))

        do {
            let casks = try await CaskDatabaseClient.caskCatalog().fetchCasks()
            let installed = try await model.brewService.installedCasks()
            let npmInstalled = (try? await model.npmService.installedGlobals()) ?? []
            npmBrewDuplicates = NpmBrewDuplicateDetector().detect(
                npmPackages: npmInstalled,
                brewTokens: installed
            )
            let all = await Self.scanApplicationDirectories(
                buildScanDirs(),
                installedCasks: installed,
                availableCasks: casks
            )
            let migrationPool = MigrationPlanner.migrationPool(
                InstallationInventory.deduplicated(all)
            )
            candidates = migrationPool
            publisherCorrelations = await Self.publisherCorrelations(
                for: migrationPool,
                using: publisherCorrelator
            )

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
            publisherCorrelations = [:]
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

    /// ARCH-05c — the `/Applications` walk (directory enumeration plus each app's `Info.plist`
    /// read) is synchronous filesystem I/O. It runs here, off the MainActor, so
    /// `scanCoordinated` can keep mutating its `@Published` state on the main thread without the
    /// scan blocking it. `nonisolated` is what moves the work off the MainActor: an `async`
    /// nonisolated member suspends the caller and resumes on the generic executor. The injected
    /// `scan` seam mirrors `InventorySources.scanApplications` / `UninstallScan.collect`, so a
    /// test can observe the executor without touching the disk.
    nonisolated static func scanApplicationDirectories(
        _ directories: [URL],
        installedCasks: Set<String>,
        availableCasks: [BrewCask],
        scan: @Sendable (URL, Set<String>, [BrewCask]) throws -> [ApplicationInfo] = { directory, installed, available in
            try ApplicationScanner().scanApplications(
                in: directory,
                installedCasks: installed,
                availableCasks: available
            )
        }
    ) async -> [ApplicationInfo] {
        directories.flatMap { directory in
            (try? scan(directory, installedCasks, availableCasks)) ?? []
        }
    }

    /// LT-03 — publisher corroboration for the whole candidate list, in one pass, off the
    /// MainActor (`nonisolated` + `async`, the same boundary `scanApplicationDirectories`
    /// uses): reading a bundle's code signature is filesystem and Security-framework work.
    /// Doing it here, once per scan, is what lets `MigrationRow` render the confidence badge
    /// from a stored value instead of signature-checking on every SwiftUI body evaluation.
    /// The correlator itself only opens the bundles whose cask has a recorded publisher, so
    /// the common scan pays nothing at all.
    nonisolated static func publisherCorrelations(
        for applications: [ApplicationInfo],
        using correlator: CaskPublisherCorrelator
    ) async -> [String: CaskPublisherCorrelation] {
        correlator.correlations(for: applications)
    }

    /// The same correlation for a single app, measured fresh at the moment of takeover.
    nonisolated static func publisherCorrelation(
        for app: ApplicationInfo,
        token: String,
        using correlator: CaskPublisherCorrelator
    ) async -> CaskPublisherCorrelation {
        correlator.correlate(caskToken: token, appPath: app.path)
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
                // SEC-10: `--` fences the token off from Homebrew's option parsing.
                arguments: ["install", "--cask", "--force", "--", token]
            )
            exitCode = try await ProcessEventStream.drain(stream) { chunk in
                let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    logLines = ProcessEventStream.appendingCapped([trimmed], to: logLines)
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
                    // SEC-10: `--` fences the token off from Homebrew's option parsing.
                    arguments: ["uninstall", "--", removal.dup.brewToken]
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
            exitCode = try await ProcessEventStream.drain(stream) { chunk in
                logLines = ProcessEventStream.appendingCapped(
                    ProcessEventStream.lines(from: chunk, trimmingWhitespace: true), to: logLines
                )
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
