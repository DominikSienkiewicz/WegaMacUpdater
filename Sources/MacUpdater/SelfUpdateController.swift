import AppKit
import Foundation
import MacUpdaterCore

/// Owns the self-update state machine and every network/filesystem side effect behind it.
@MainActor
final class SelfUpdateController: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case result(WegaSelfUpdateChecker.Result)
        case downloading(WegaSelfUpdateChecker.Result?)
        /// Terminal state of a headless install: the new bundle is on disk, the running process
        /// is still the old one. Only a user click leaves this state.
        case installedPendingRestart(version: String)
        case installationUncertain
    }

    struct Dependencies: Sendable {
        var check: @Sendable () async -> WegaSelfUpdateChecker.Result
        var download: @Sendable (URL) async throws -> URL
        /// SEC-04 — the second argument is the version the release promised, so the payload
        /// is pinned to the update the user was actually shown, not just to a valid signature.
        var verify: @Sendable (URL, String?) throws -> Void
        var installOrOpen: @MainActor @Sendable (SelfUpdateAction, URL) async throws -> Bool
        var openFallback: @MainActor @Sendable () -> Void
        /// Quit and come back on the freshly installed bundle.
        var relaunch: @MainActor @Sendable () -> Void
        /// Whether any mutating operation currently holds the write gate. Injected so the rule
        /// is testable; in production it reads the coordinator that owns the gate.
        var isBusy: @MainActor @Sendable () -> Bool
        /// The cumulative notes between the installed version and the newest one.
        var fetchHistory: @Sendable (String) async -> ReleaseHistoryFetcher.Outcome
        var installTracked: (@MainActor @Sendable (URL, String) async throws -> Bool)? = nil
        var hasPendingInstallation: @MainActor @Sendable () -> Bool = { false }
        var reconcileInstallation: (@MainActor @Sendable () async throws -> PendingHelperInstallation?)? = nil

        static let live = Dependencies(
            check: { await WegaSelfUpdateChecker().check() },
            download: { source in
                let (temporary, _) = try await URLSession.shared.download(from: source)
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(source.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                return destination
            },
            verify: { destination, expectedVersion in
                try CodeSignatureVerifier.verify(
                    installerAt: destination,
                    expectedTeamID: WegaHelper.teamIdentifier,
                    bundleID: AppMetadata.bundleIdentifier,
                    expectedVersion: expectedVersion
                )
            },
            installOrOpen: { action, destination in
                guard case .downloadAndOpen = action else { throw PackagePayloadVerifier.Failure.missingExpectation }
                NSWorkspace.shared.open(destination)
                return false
            },
            openFallback: {
                NSWorkspace.shared.open(AppEndpoints.shared.projectRepositoryURL)
            },
            relaunch: {
                // The replacement process must start *after* this one exits, or the single-instance
                // guard rejects it. A detached shell waits, then reopens the bundle by path.
                let relauncher = Process()
                relauncher.executableURL = SystemPaths.posixShell
                relauncher.arguments = ["-c", #"sleep 1; /usr/bin/open "$0""#, Bundle.main.bundleURL.path]
                do {
                    try relauncher.run()
                } catch {
                    WegaLog.error(.app, "Self-update — ponowne uruchomienie: \(error.localizedDescription)")
                    return
                }
                NSApp.terminate(nil)
            },
            isBusy: { UpgradeCoordinator.shared.state != .idle },
            fetchHistory: { installed in
                await ReleaseHistoryFetcher().notesNewerThan(installed)
            },
            installTracked: { destination, version in
                try await PrivilegedHelperClient.shared.installVerifiedPackage(at: destination.path, version: version)
                return true
            },
            hasPendingInstallation: { PendingHelperInstallationStore.shared.hasPending },
            reconcileInstallation: {
                try await PrivilegedHelperClient.shared.reconcilePackageInstallation()
            }
        )
    }

    @Published private(set) var state: State = .idle
    /// `nil` until an update is found — there is nothing to explain when the app is current.
    @Published private(set) var history: ReleaseHistoryFetcher.Outcome?
    @Published private(set) var isReconcilingInstallation = false

    private let dependencies: Dependencies
    private let upgrades: UpgradeCoordinator

    init(
        dependencies: Dependencies = .live,
        upgrades: UpgradeCoordinator = .shared
    ) {
        self.dependencies = dependencies
        self.upgrades = upgrades
        if dependencies.hasPendingInstallation() { state = .installationUncertain }
    }

    var result: WegaSelfUpdateChecker.Result? {
        switch state {
        case .result(let result): return result
        case .downloading(let result): return result
        case .idle, .checking, .installedPendingRestart, .installationUncertain: return nil
        }
    }

    var isChecking: Bool { state == .checking }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    func check() async {
        guard !isChecking, !isDownloading, state != .installationUncertain else { return }
        // The doc comment on `installedPendingRestart` above promises only a user click leaves
        // that state. `InfoView.onAppear`'s `if case .idle` gate is one caller honouring that —
        // but the invariant belongs to the controller that owns the state, not to every caller.
        guard !isInstalledPendingRestart else { return }
        state = .checking
        let outcome = await dependencies.check()
        state = .result(outcome)

        guard case .updateAvailable = outcome else {
            history = nil
            return
        }
        history = await dependencies.fetchHistory(AppMetadata.version)
    }

    private var isInstalledPendingRestart: Bool {
        if case .installedPendingRestart = state { return true }
        return false
    }

    /// True only when a restart would not interrupt a mutating operation. The write gate is the
    /// authority — this never tracks a second flag of its own.
    var canRestart: Bool {
        if case .installedPendingRestart = state { return !dependencies.isBusy() }
        return false
    }

    func restart() {
        guard canRestart else { return }
        dependencies.relaunch()
    }

    func reconcileInstallation(onWegaState: @MainActor (WegaState) -> Void) async {
        guard !isReconcilingInstallation, let reconcile = dependencies.reconcileInstallation else { return }
        isReconcilingInstallation = true
        defer {
            isReconcilingInstallation = false
            upgrades.refreshExternalMutationState()
        }
        do {
            if let pending = try await reconcile() {
                state = .installedPendingRestart(version: pending.version)
                onWegaState(WegaState(pose: .happy, line: SelfUpdatePresentation.message(for: .installed)))
            } else {
                state = .idle
            }
        } catch {
            WegaLog.error(.helper, "Odczyt wyniku instalacji: \(error.localizedDescription)")
            let pending = dependencies.hasPendingInstallation()
            state = pending ? .installationUncertain : .idle
            onWegaState(WegaState(pose: .alert, line: pending ? Self.uncertainMessage : SelfUpdatePresentation.message(for: .failed)))
        }
    }

    private static var uncertainMessage: String {
        tr("Wynik instalacji jest nieznany. Dalsze zmiany są zablokowane — sprawdź stan instalacji w Ustawieniach.")
    }

    func apply(
        _ action: SelfUpdateAction,
        version: String,
        onWegaState: @MainActor (WegaState) -> Void
    ) async {
        guard !isDownloading else { return }
        guard state != .installationUncertain, !dependencies.hasPendingInstallation() else {
            state = .installationUncertain
            onWegaState(WegaState(pose: .alert, line: Self.uncertainMessage))
            return
        }
        let previousResult = result
        let expectedVersion = previousResult?.availableVersion ?? version
        state = .downloading(previousResult)
        var finalState: State = previousResult.map(State.result) ?? .idle
        defer { state = finalState }

        let source = action.asset.url

        // UX-06 — `download` is its own state, distinct from `open`/`install`/`error`.
        onWegaState(WegaState(pose: .sniff, line: SelfUpdatePresentation.message(for: .downloading)))

        let destination: URL
        do {
            destination = try await dependencies.download(source)
        } catch {
            // The technical error stays in the log; the user sees a localized message (UX-06).
            WegaLog.error(.network, "Self-update — pobieranie: \(error.localizedDescription)")
            onWegaState(WegaState(pose: .alert, line: SelfUpdatePresentation.message(for: .failed)))
            dependencies.openFallback()
            return
        }

        do {
            let verify = dependencies.verify
            try await Task.detached(priority: .userInitiated) {
                try verify(destination, expectedVersion)
            }.value
        } catch {
            WegaLog.error(.app, "Self-update odrzucony: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: destination)
            onWegaState(WegaState(
                pose: .alert,
                line: tr("Aktualizacja nie przeszła weryfikacji podpisu — otwieram stronę wydania.")
            ))
            dependencies.openFallback()
            return
        }

        let installed: Bool
        do {
            installed = try await upgrades.performWrite(.selfUpdate) {
                let ticket = MutationGuard.shared.begin("self-update")
                defer { MutationGuard.shared.end(ticket) }
                if case .install = action, let install = self.dependencies.installTracked {
                    return try await install(destination, expectedVersion)
                }
                return try await self.dependencies.installOrOpen(action, destination)
            }
        } catch is CancellationError {
            return
        } catch {
            WegaLog.error(.helper, "Instalacja przez helper nie powiodła się: \(error.localizedDescription)")
            if dependencies.hasPendingInstallation() {
                finalState = .installationUncertain
                onWegaState(WegaState(pose: .alert, line: Self.uncertainMessage))
            } else if await openVerifiedPackage(for: action, at: destination) {
                onWegaState(WegaState(pose: .happy, line: SelfUpdatePresentation.message(for: .opened)))
            } else {
                onWegaState(WegaState(pose: .alert, line: SelfUpdatePresentation.message(for: .failed)))
            }
            return
        }

        // UX-06 — `install` (headless, via the helper) and `open` (the user finishes a
        // downloaded installer) are separate outcomes with separate messages.
        if installed { finalState = .installedPendingRestart(version: expectedVersion) }
        onWegaState(WegaState(
            pose: .happy,
            line: SelfUpdatePresentation.message(for: installed ? .installed : .opened)
        ))
    }

    /// Hands an already verified package to Installer.app after the helper refused it before
    /// anything was submitted, so a broken helper never blocks the update.
    private func openVerifiedPackage(for action: SelfUpdateAction, at destination: URL) async -> Bool {
        guard case .install(let pkg) = action, dependencies.installTracked != nil else { return false }
        do {
            _ = try await dependencies.installOrOpen(.downloadAndOpen(asset: pkg), destination)
            return true
        } catch {
            WegaLog.error(.app, "Self-update — otwarcie instalatora: \(error.localizedDescription)")
            return false
        }
    }
}
