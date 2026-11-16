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

/// UX-13: the `~/Library` leftovers of one non-brew uninstall target that still exist on
/// disk, so the confirm sheet can offer them as checkboxes before anything is removed.
struct LeftoverGroup: Identifiable, Equatable, Sendable {
    let app: ApplicationInfo
    let items: [URL]

    var id: String { app.id }
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
    /// Homebrew or the user's real Trash.
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
            bundleFacts: { UninstallBundleFacts.live(path: $0.path, hasBundleIdentifier: $0.bundleIdentifier != nil) }
        )
    }

    struct Outcome {
        /// One result per target id.
        let results: [String: UninstallTargetResult]
        /// UX-13: how many consented `~/Library` leftovers reached the Trash, and how many
        /// could not be moved, so the result is reported honestly rather than swallowed.
        var leftoversTrashed: Int = 0
        var leftoversFailed: Int = 0
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
    /// happen before the user consents. Brew-managed targets keep the Homebrew path.
    func routes(for targets: [ApplicationInfo]) -> [String: UninstallRouteDecision] {
        Dictionary(uniqueKeysWithValues: targets.filter { !$0.isManagedByBrew }.map {
            ($0.id, UninstallRoute.preflight(dependencies.bundleFacts($0)))
        })
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

    /// UX-13: plans the `~/Library` leftovers for the non-brew targets, so the confirm
    /// sheet can present them as checkboxes before the user consents.
    ///
    /// Brew casks clean their own `~/Library` via `brew uninstall --zap`, so they are
    /// excluded here — the "app + leftovers" promise holds for both sources, by two
    /// mechanisms that never overlap. One group is returned per app that actually has
    /// leftovers on disk; apps with none (or without a bundle id) are dropped. Planning
    /// runs off the main actor because it touches the filesystem.
    func scanLeftovers(
        for targets: [ApplicationInfo],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> [LeftoverGroup] {
        await Task.detached(priority: .userInitiated) {
            targets.compactMap { app -> LeftoverGroup? in
                guard !app.isManagedByBrew, let bundleID = app.bundleIdentifier else { return nil }
                let items = LeftoverCleanup.plan(bundleID: bundleID, home: home)
                return items.isEmpty ? nil : LeftoverGroup(app: app, items: items)
            }
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
                results[app.id] = removeNonBrew(app)
            }
        }
        // UX-13: only an app that was actually removed releases its consented `~/Library`
        // leftovers; the data of an app that stays installed is never touched.
        let releasedLeftovers = leftovers
            .filter { results[$0.id]?.isRemoved == true }
            .flatMap(\.items)
        let leftoverResult = dependencies.trashLeftovers(releasedLeftovers)
        return Outcome(
            results: results,
            leftoversTrashed: leftoverResult.removed.count,
            leftoversFailed: leftoverResult.failed.count
        )
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
    private func removeNonBrew(_ app: ApplicationInfo) -> UninstallTargetResult {
        let facts = dependencies.bundleFacts(app)
        if case .blocked(let block) = UninstallRoute.preflight(facts) { return .blocked(block) }
        do {
            try dependencies.trashItem(app.path)
            return .movedToTrash
        } catch {
            guard UninstallRoute.isPermissionDenied(error) else { return .failed(error.localizedDescription) }
            switch UninstallRoute.afterPermissionDenied(facts) {
            case .blocked(let block): return .blocked(block)
            // Milestone B adds the helper removal here; until then it reads as "needs the helper".
            case .helper: return .blocked(.needsHelper)
            case .userTrash: return .failed(error.localizedDescription)
            }
        }
    }
}
