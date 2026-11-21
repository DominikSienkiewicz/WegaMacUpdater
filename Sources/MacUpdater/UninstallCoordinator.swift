import Foundation
import MacUpdaterCore

/// REL-14: the result of an uninstall scan — the apps found plus every source that
/// failed. `UninstallView` keeps the two apart so a scan failure is never rendered as
/// "no apps found", and warns before a destructive action taken on partial data.
struct UninstallScan: Equatable, Sendable {
    let apps: [ApplicationInfo]
    let failures: [ScanSourceFailure]
    /// Apps that must never be offered for removal, keyed by `ApplicationInfo.id`.
    let protections: [String: UninstallProtection]

    var scanFailed: Bool { !failures.isEmpty }

    init(
        apps: [ApplicationInfo],
        failures: [ScanSourceFailure] = [],
        protections: [String: UninstallProtection] = [:]
    ) {
        self.apps = apps
        self.failures = failures
        self.protections = protections
    }

    /// Runs each uninstall source, recording a `ScanSourceFailure` for one that throws
    /// rather than dropping it, and keeps the apps found by the sources that succeeded.
    /// Cancellation is not a scan failure, so it is never recorded.
    static func collect(
        directories: [URL],
        installedCasks: () async throws -> Set<String>,
        scanApplications: (_ directory: URL, _ installedCasks: Set<String>) throws -> [ApplicationInfo],
        protections: ([ApplicationInfo]) -> [String: UninstallProtection] = {
            UninstallEligibility.protections(for: $0)
        }
    ) async -> UninstallScan {
        var failures: [ScanSourceFailure] = []

        var installedCaskTokens: Set<String> = []
        do { installedCaskTokens = try await installedCasks() }
        catch is CancellationError {
            // Cancellation is intentionally not recorded as a source failure.
        }
        catch { failures.append(ScanSourceFailure(source: .homebrew, message: error.localizedDescription)) }

        var found: [ApplicationInfo] = []
        var applicationsFailure: ScanSourceFailure?
        for directory in directories {
            do {
                found.append(contentsOf: try scanApplications(directory, installedCaskTokens))
            } catch is CancellationError {
                // Navigation cancelled the scan — not a source failure.
            } catch {
                applicationsFailure = applicationsFailure
                    ?? ScanSourceFailure(source: .applications, message: error.localizedDescription)
            }
        }
        if let applicationsFailure { failures.append(applicationsFailure) }

        let apps = InstallationInventory.deduplicated(found)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return UninstallScan(apps: apps, failures: failures, protections: protections(apps))
    }
}

/// UX-13: the leftovers of one non-brew uninstall target that still exist on disk, as
/// `LeftoverPlanner` labelled them, so the confirm sheet can offer them before anything is removed.
struct LeftoverGroup: Identifiable, Equatable, Sendable {
    let app: ApplicationInfo
    let items: [LeftoverItem]

    var id: String { app.id }
}

/// The leftovers planned for one uninstall, and whether the cask catalog — and with it every
/// Homebrew zap list — could not be loaded.
struct LeftoverScan: Equatable, Sendable {
    var groups: [LeftoverGroup]
    var catalogUnavailable: Bool
}

/// The apps of one uninstall as the leftover planner sees them: the non-brew targets it plans,
/// the brew targets removed alongside them, and the installed apps that stay.
private struct LeftoverPlanningRun: Sendable {
    let planned: [ApplicationInfo]
    let alsoRemoved: [ApplicationInfo]
    let others: [ApplicationInfo]

    init(targets: [ApplicationInfo], installed: [ApplicationInfo]) {
        planned = targets.filter { !$0.isManagedByBrew }
        alsoRemoved = targets.filter(\.isManagedByBrew)
        let targetIDs = Set(targets.map(\.id))
        others = installed.filter { !targetIDs.contains($0.id) }
    }

    /// Matches every app of the run to `catalog`, reads the planned targets' team ids and plans.
    /// The planned targets' matches honour the channel policy, because their zap lists are offered;
    /// the other apps' matches do not, because theirs only say what those apps still use.
    func groups(
        catalog: [BrewCask]?,
        home: URL,
        teamIdentifier: (URL) -> String?,
        fileSystem: any CleanupFileSystem
    ) -> [LeftoverGroup] {
        let offered = catalog.map { LeftoverCaskMatching.evidence(for: planned, casks: $0) } ?? [:]
        let claiming = catalog.map {
            LeftoverCaskMatching.evidence(for: alsoRemoved + others, casks: $0, honouringChannelPolicy: false)
        } ?? [:]
        let unsigned = { (app: ApplicationInfo) in LeftoverApp(app, teamIdentifier: nil, cask: claiming[app.id]) }
        let plan = LeftoverPlanner.plan(
            targets: planned.map { LeftoverApp($0, teamIdentifier: teamIdentifier($0.path), cask: offered[$0.id]) },
            alsoRemoved: alsoRemoved.map(unsigned),
            others: others.map(unsigned),
            home: home,
            fileSystem: fileSystem
        )
        let plannedByID = Dictionary(planned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.compactMap { group in
            plannedByID[group.appID].map { LeftoverGroup(app: $0, items: group.items) }
        }
    }
}

/// The outcome of asking running apps to quit, keyed by `ApplicationInfo.id`.
struct UninstallQuitResult: Equatable {
    /// Targets that are no longer running, including those that never were.
    var stopped: Set<String> = []
    /// Targets whose process is still alive.
    var stillRunning: [ApplicationInfo] = []
    /// Targets that cannot be told apart from another copy of the app, so no process
    /// was asked to quit or killed.
    var ambiguous: Set<String> = []
}

/// Performs application discovery and destructive uninstall I/O outside SwiftUI.
@MainActor
final class UninstallCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case quitting
        case uninstalling
    }

    /// The side effects the coordinator performs, injectable so tests drive removal without
    /// Homebrew, the root helper or the user's real Trash.
    struct Dependencies: Sendable {
        var uninstallCask: @Sendable (BrewService, _ token: String, _ zap: Bool) async throws -> Void
        var trashItem: @Sendable (URL) throws -> Void
        var trashLeftovers: @Sendable ([URL]) -> LeftoverCleanup.Result
        var protection: @Sendable (ApplicationInfo) -> UninstallProtection?
        var runningApplications: @MainActor @Sendable () -> [RunningApplicationTarget]
        var requestQuit: @MainActor @Sendable (RunningApplicationTarget) -> Bool
        var forceKill: @Sendable (Int32) async -> Bool
        var waitBetweenRunningChecks: @Sendable () async -> Void
        var bundleFacts: @Sendable (ApplicationInfo) -> UninstallBundleFacts
        /// Has Wega's helper move a root-owned app into a staging slot this user owns; returns
        /// where the bundle now is.
        var stageForTrash: @Sendable (_ path: URL, _ bundleID: String) async throws -> URL
        /// One bounded handshake with the helper, run before the sheet promises its route.
        var helperHandshake: @Sendable () async -> UninstallHelperAvailability = { .enabled }
        /// The cask catalog whose zap lists name leftovers; nil when it cannot be loaded.
        var loadCaskCatalog: @Sendable () async -> [BrewCask]? = { nil }
        /// The team id an app bundle is signed with, which names its group containers.
        var teamIdentifier: @Sendable (URL) -> String? = { _ in nil }
        /// The planner and the size measurement read the disk only through this.
        var leftoverFileSystem: any CleanupFileSystem = LiveCleanupFileSystem()

        static let live = Dependencies(
            uninstallCask: { brewService, token, zap in
                _ = try await brewService.uninstallCask(token: token, zap: zap)
            },
            trashItem: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
            trashLeftovers: { LeftoverCleanup.removeToTrash($0) },
            protection: { UninstallEligibility.protections(for: [$0])[$0.id] },
            runningApplications: { WorkspaceRunningApplicationInspector().runningApplications() },
            requestQuit: { WorkspaceTargetTerminator().requestGracefulTermination($0) },
            forceKill: { await RunningProcessService().forceKill(processIdentifier: $0) },
            waitBetweenRunningChecks: { try? await Task.sleep(for: .milliseconds(250)) },
            bundleFacts: {
                UninstallBundleFacts.live(
                    path: $0.path,
                    hasBundleIdentifier: $0.bundleIdentifier != nil,
                    helper: PrivilegedHelperClient.shared.uninstallAvailability
                )
            },
            stageForTrash: { try await PrivilegedHelperClient.shared.stageApplicationBundleForTrash(at: $0, expectedBundleID: $1) },
            helperHandshake: { await PrivilegedHelperClient.shared.uninstallAvailabilityAfterHandshake() },
            loadCaskCatalog: { try? await CaskDatabaseClient.uninstallCatalog().fetchCasksAcceptingStaleCache() },
            teamIdentifier: { CodeSignatureVerifier.teamID(ofAppAt: $0) }
        )
    }

    struct Outcome {
        /// One result per target id.
        let results: [String: UninstallTargetResult]
        /// UX-13: how many consented home-folder leftovers reached the Trash, and how many
        /// could not be moved, so the result is reported honestly rather than swallowed.
        var leftoversTrashed: Int = 0
        var leftoversFailed: Int = 0
    }

    /// The helper took the request but never answered: it may have moved the app already, so
    /// the result must not read as "nothing happened". The rescan after the run shows the truth.
    static var unconfirmedHelperRemoval: String {
        tr("Pomocnik Wegi nie potwierdził usunięcia — aplikacja mogła już opuścić /Applications. Odświeżona lista pokazuje, czy nadal tam jest.")
    }

    @Published private(set) var state: State = .idle

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    var isScanning: Bool { state == .scanning }
    var isUninstalling: Bool { state == .uninstalling }
    /// True while apps are being asked to quit, including while the user answers the
    /// force-quit sheet, so a second confirmation cannot start a parallel run.
    var isQuitting: Bool { state == .quitting }

    /// Claims the coordinator for the quit phase. Returns `false` when another phase owns it.
    func beginQuitPhase() -> Bool {
        guard state == .idle else { return false }
        state = .quitting
        return true
    }

    func endQuitPhase() {
        if state == .quitting { state = .idle }
    }

    /// The route each non-brew target would take, so the confirmation sheet can say what will
    /// happen before the user consents. Brew-managed targets keep the Homebrew path. When a
    /// target would use the helper, one bounded handshake first checks that it is current, so a
    /// stale or silent helper blocks the target before anything is quit.
    func routes(for targets: [ApplicationInfo]) async -> [String: UninstallRouteDecision] {
        let factsByID = Dictionary(uniqueKeysWithValues: targets.filter { !$0.isManagedByBrew }.map {
            ($0.id, dependencies.bundleFacts($0))
        })
        let preflight = factsByID.mapValues { UninstallRoute.preflight($0) }
        guard preflight.values.contains(.helper) else { return preflight }
        let handshake = await dependencies.helperHandshake()
        return factsByID.mapValues { facts in
            var checked = facts
            if facts.helper == .enabled { checked.helper = handshake }
            return UninstallRoute.preflight(checked)
        }
    }

    func runningStates(for targets: [ApplicationInfo]) -> [String: RunningApplicationResolution] {
        resolveAll(targets)
    }

    /// Asks every running target to quit before polling them all together. A refused
    /// request is not a failure by itself: the app may still quit after a save prompt.
    func requestQuit(_ targets: [ApplicationInfo]) async -> UninstallQuitResult {
        var result = UninstallQuitResult()
        var pending: [ApplicationInfo] = []
        let states = resolveAll(targets)
        for app in targets {
            switch states[app.id] ?? .notRunning {
            case .notRunning: result.stopped.insert(app.id)
            case .ambiguousBundleIdentifier: result.ambiguous.insert(app.id)
            case .running(let target):
                _ = dependencies.requestQuit(target)
                pending.append(app)
            }
        }
        await pollUntilStopped(pending, into: &result)
        return result
    }

    /// Asks the targets Wega will attempt to quit, lets the user decide about those that
    /// refuse, and returns what may be removed. A target whose preflight route is blocked is
    /// never asked to quit or force-quit: nothing of it will be removed, so it is reported as
    /// blocked as it stands. `nil` means the user cancelled: nothing is removed.
    func runQuitPhase(
        targets: [ApplicationInfo],
        routes: [String: UninstallRouteDecision],
        askForceQuit: @MainActor (_ stillRunning: [ApplicationInfo]) async -> UninstallForceQuitChoice
    ) async -> UninstallQuitFlow.Plan? {
        let split = UninstallQuitFlow.partition(targets: targets, routes: routes)
        let quit = await requestQuit(split.attempt)
        var choice: UninstallForceQuitChoice?
        var forced: UninstallQuitResult?
        if !quit.stillRunning.isEmpty {
            let answer = await askForceQuit(quit.stillRunning)
            choice = answer
            if answer == .forceQuit { forced = await forceQuit(quit.stillRunning) }
        }
        guard let plan = UninstallQuitFlow.plan(targets: split.attempt, quit: quit, choice: choice, forced: forced)
        else { return nil }
        return (plan.remove, plan.skipped.merging(split.blocked) { quitResult, _ in quitResult })
    }

    /// Kills only the process each app resolves to right now, never one resolved earlier:
    /// the app may have quit, or relaunched under a new PID, since the quit phase.
    func forceQuit(_ apps: [ApplicationInfo]) async -> UninstallQuitResult {
        var result = UninstallQuitResult()
        var pending: [ApplicationInfo] = []
        for app in apps {
            switch resolveAll([app])[app.id] ?? .notRunning {
            case .notRunning: result.stopped.insert(app.id)
            case .ambiguousBundleIdentifier: result.ambiguous.insert(app.id)
            case .running(let target):
                if await dependencies.forceKill(target.processIdentifier) {
                    pending.append(app)
                } else {
                    result.stillRunning.append(app)
                }
            }
        }
        await pollUntilStopped(pending, into: &result)
        return result
    }

    private static let runningCheckRounds = 10

    private func pollUntilStopped(_ apps: [ApplicationInfo], into result: inout UninstallQuitResult) async {
        var pending = apps
        for round in 0..<Self.runningCheckRounds where !pending.isEmpty {
            let states = resolveAll(pending)
            pending = pending.filter { app in
                switch states[app.id] ?? .notRunning {
                case .notRunning:
                    result.stopped.insert(app.id)
                    return false
                case .ambiguousBundleIdentifier:
                    result.ambiguous.insert(app.id)
                    return false
                case .running:
                    return true
                }
            }
            if !pending.isEmpty, round < Self.runningCheckRounds - 1 {
                await dependencies.waitBetweenRunningChecks()
            }
        }
        result.stillRunning.append(contentsOf: pending)
    }

    private func resolveAll(_ targets: [ApplicationInfo]) -> [String: RunningApplicationResolution] {
        let running = dependencies.runningApplications()
        return Dictionary(uniqueKeysWithValues: targets.map {
            ($0.id, UninstallRunningApplicationResolver.resolve(app: $0, running: running))
        })
    }

    /// Returns `nil` when another phase owns the coordinator, so a caller keeps the list it
    /// has instead of replacing it with an empty result.
    func scan(using brewService: BrewService) async -> UninstallScan? {
        guard state == .idle else { return nil }
        state = .scanning
        defer { state = .idle }

        let directories = buildScanDirs()
        do {
            return try await OperationCoordinator.shared.withRead(label: "uninstall scan") {
                let scanner = ApplicationScanner()
                return await UninstallScan.collect(
                    directories: directories,
                    installedCasks: { try await brewService.installedCasks() },
                    scanApplications: { directory, installedCasks in
                        try scanner.scanApplications(in: directory, installedCasks: installedCasks)
                    }
                )
            }
        } catch {
            return UninstallScan(apps: [])
        }
    }

    /// UX-13: plans the leftovers of the non-brew targets with `LeftoverPlanner`, so the
    /// confirm sheet can present them before the user consents.
    ///
    /// Brew casks clean their own leftovers via `brew uninstall --zap`, so they are not planned,
    /// but they still claim the items they share with a planned target. `installed` is the whole
    /// Uninstall scan: every app in it that is not a target stays installed, including a target
    /// left out because its route is blocked. The cask catalog is loaded only when something is
    /// planned; cask matching, reading team ids and planning run off the main actor.
    /// One group is returned per target that has leftovers on disk.
    func scanLeftovers(
        for targets: [ApplicationInfo],
        installed: [ApplicationInfo],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> LeftoverScan {
        let run = LeftoverPlanningRun(targets: targets, installed: installed)
        guard !run.planned.isEmpty else { return LeftoverScan(groups: [], catalogUnavailable: false) }
        let catalog = await dependencies.loadCaskCatalog()
        let teamIdentifier = dependencies.teamIdentifier
        let fileSystem = dependencies.leftoverFileSystem
        let groups = await Task.detached(priority: .userInitiated) {
            run.groups(catalog: catalog, home: home, teamIdentifier: teamIdentifier, fileSystem: fileSystem)
        }.value
        return LeftoverScan(groups: groups, catalogUnavailable: catalog == nil)
    }

    /// The size of one planned leftover, measured off the main actor.
    func measureLeftover(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> LeftoverSize {
        let fileSystem = dependencies.leftoverFileSystem
        return await Task.detached(priority: .userInitiated) {
            LeftoverSizing.measure(url, home: home, fileSystem: fileSystem)
        }.value
    }

    func uninstall(
        targets: [ApplicationInfo],
        zap: Bool,
        leftovers: [LeftoverGroup] = [],
        skipped: [String: UninstallTargetResult] = [:],
        using brewService: BrewService
    ) async -> Outcome {
        do {
            return try await UpgradeCoordinator.shared.performWrite(.uninstall) {
                await self.uninstallCoordinated(
                    targets: targets,
                    zap: zap,
                    leftovers: leftovers,
                    skipped: skipped,
                    using: brewService
                )
            }
        } catch {
            let failure = UninstallTargetResult.failed(error.localizedDescription)
            let failed = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, failure) })
            return Outcome(results: failed.merging(skipped) { _, skip in skip })
        }
    }

    private func uninstallCoordinated(
        targets: [ApplicationInfo],
        zap: Bool,
        leftovers: [LeftoverGroup],
        skipped: [String: UninstallTargetResult],
        using brewService: BrewService
    ) async -> Outcome {
        state = .uninstalling
        defer { state = .idle }

        var results = skipped
        for app in targets {
            if let protection = dependencies.protection(app) {
                results[app.id] = .protected(protection)
            } else if let stillRunning = runningAtRemoval(app) {
                results[app.id] = stillRunning
            } else if app.isManagedByBrew, let token = app.caskToken {
                do {
                    try await dependencies.uninstallCask(brewService, token, zap)
                    results[app.id] = .removedByHomebrew
                } catch {
                    results[app.id] = .failed(error.localizedDescription)
                }
            } else {
                results[app.id] = await removeNonBrew(app)
            }
        }
        let leftoverResult = dependencies.trashLeftovers(Self.releasedLeftovers(leftovers, results: results))
        return Outcome(
            results: results,
            leftoversTrashed: leftoverResult.removed.count,
            leftoversFailed: leftoverResult.failed.count
        )
    }

    /// UX-13: a consented leftover is released only when its own app and every other target that
    /// claims it (`coTargets`) were actually removed; the data of an app that stays installed is
    /// never touched.
    private static func releasedLeftovers(
        _ leftovers: [LeftoverGroup],
        results: [String: UninstallTargetResult]
    ) -> [URL] {
        let isRemoved = { (id: String) in results[id]?.isRemoved == true }
        return leftovers.flatMap { group in
            group.items.filter { isRemoved(group.id) && $0.coTargets.allSatisfy(isRemoved) }.map(\.url)
        }
    }

    /// The quit phase decided "stopped" before the force-quit sheet and the write lease, both of
    /// which can wait; the app may have been relaunched since. Resolved again right before its
    /// bundle would go, so nothing is removed while its process is confirmed running.
    private func runningAtRemoval(_ app: ApplicationInfo) -> UninstallTargetResult? {
        switch resolveAll([app])[app.id] ?? .notRunning {
        case .notRunning: nil
        case .running: .skippedStillRunning
        case .ambiguousBundleIdentifier: .skippedAmbiguousProcess
        }
    }

    /// Moves one non-brew bundle to the user's Trash unless its route is already blocked.
    /// Only a permission refusal is re-routed; any other error is the app's real failure.
    private func removeNonBrew(_ app: ApplicationInfo) async -> UninstallTargetResult {
        let facts = dependencies.bundleFacts(app)
        if case .blocked(let block) = UninstallRoute.preflight(facts) { return .blocked(block) }
        do {
            try dependencies.trashItem(app.path)
            return .movedToTrash
        } catch {
            guard UninstallRoute.isPermissionDenied(error) else { return .failed(error.localizedDescription) }
            switch UninstallRoute.afterPermissionDenied(facts) {
            case .blocked(let block): return .blocked(block)
            case .helper: return await removeThroughHelper(app)
            case .userTrash: return .failed(error.localizedDescription)
            }
        }
    }

    /// The helper moves the root-owned bundle into a slot this user owns; the bundle then goes to
    /// the Trash as the user. A bundle the Trash refuses stays in that slot, out of
    /// `/Applications`, and nothing is deleted.
    private func removeThroughHelper(_ app: ApplicationInfo) async -> UninstallTargetResult {
        guard let bundleID = app.bundleIdentifier else { return .blocked(.needsAdministratorRights) }
        let staged: URL
        do {
            staged = try await dependencies.stageForTrash(app.path, bundleID)
        } catch let failure as PrivilegedHelperClient.StagingFailure {
            return Self.helperFailure(failure.underlying, requestSent: failure.requestSent)
        } catch {
            // Without its phase the request may have been sent, so the app may already be gone.
            return Self.helperFailure(error, requestSent: true)
        }
        do {
            try dependencies.trashItem(staged)
            return .movedToTrashByHelper
        } catch {
            return .leftInStaging(staged)
        }
    }

    /// A helper that is not registered needs turning on. One that is stale, or did not answer
    /// before the request was sent, must be reinstalled: nothing happened to the app. No answer
    /// after the request was sent is not a plain failure, because the app may already be gone.
    static func helperFailure(_ error: Error, requestSent: Bool) -> UninstallTargetResult {
        switch error as? PrivilegedHelperClient.HelperError {
        case .notEnabled:
            return .blocked(.needsHelper)
        case .versionMismatch:
            return .blocked(.helperNeedsReinstall)
        case .operationFailed(let message):
            return .failed(message)
        case .teamIDNotConfigured, .bundleNotTrusted:
            return .failed(error.localizedDescription)
        case .timedOut, .connectionFailed, nil:
            guard requestSent else { return .blocked(.helperNeedsReinstall) }
            return .failed(unconfirmedHelperRemoval)
        }
    }
}
