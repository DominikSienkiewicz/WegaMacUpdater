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
    }

    struct Dependencies: Sendable {
        var check: @Sendable () async -> WegaSelfUpdateChecker.Result
        var download: @Sendable (URL) async throws -> URL
        var verify: @Sendable (URL) throws -> Void
        var installOrOpen: @MainActor @Sendable (SelfUpdateAction, URL) async -> Bool
        var openFallback: @MainActor @Sendable () -> Void
        /// Quit and come back on the freshly installed bundle.
        var relaunch: @MainActor @Sendable () -> Void
        /// Whether any mutating operation currently holds the write gate. Injected so the rule
        /// is testable; in production it reads the coordinator that owns the gate.
        var isBusy: @MainActor @Sendable () -> Bool

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
            verify: { destination in
                try CodeSignatureVerifier.verify(
                    installerAt: destination,
                    expectedTeamID: WegaHelper.teamIdentifier,
                    bundleID: AppMetadata.bundleIdentifier
                )
            },
            installOrOpen: { action, destination in
                // UX-06 — the same decision the button label is built from, so "install" and
                // "download and open" always describe the operation that actually runs. The
                // decision itself is made exactly once, by the caller that planned `action`;
                // this only executes it — no re-deriving install-vs-open from the file or from
                // `PrivilegedHelperClient.shared.isEnabled` a second time.
                guard case .install = action else {
                    NSWorkspace.shared.open(destination)
                    return false
                }
                do {
                    try await PrivilegedHelperClient.shared.installVerifiedPackage(at: destination.path)
                    return true
                } catch {
                    WegaLog.error(
                        .helper,
                        "Instalacja przez helper nie powiodła się: \(error.localizedDescription)"
                    )
                }
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
                relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
                relauncher.arguments = ["-c", #"sleep 1; /usr/bin/open "$0""#, Bundle.main.bundleURL.path]
                do {
                    try relauncher.run()
                } catch {
                    WegaLog.error(.app, "Self-update — ponowne uruchomienie: \(error.localizedDescription)")
                    return
                }
                NSApp.terminate(nil)
            },
            isBusy: { UpgradeCoordinator.shared.state != .idle }
        )
    }

    @Published private(set) var state: State = .idle

    private let dependencies: Dependencies
    private let upgrades: UpgradeCoordinator

    init(
        dependencies: Dependencies = .live,
        upgrades: UpgradeCoordinator = .shared
    ) {
        self.dependencies = dependencies
        self.upgrades = upgrades
    }

    var result: WegaSelfUpdateChecker.Result? {
        switch state {
        case .result(let result): return result
        case .downloading(let result): return result
        case .idle, .checking, .installedPendingRestart: return nil
        }
    }

    var isChecking: Bool { state == .checking }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    func check() async {
        guard !isChecking else { return }
        state = .checking
        state = .result(await dependencies.check())
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

    func apply(
        _ action: SelfUpdateAction,
        version: String,
        onWegaState: @MainActor (WegaState) -> Void
    ) async {
        guard !isDownloading else { return }
        let previousResult = result
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
            try dependencies.verify(destination)
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
                return await self.dependencies.installOrOpen(action, destination)
            }
        } catch is CancellationError {
            return
        } catch {
            WegaLog.error(.app, "Self-update — koordynacja instalacji: \(error.localizedDescription)")
            return
        }

        // UX-06 — `install` (headless, via the helper) and `open` (the user finishes a
        // downloaded installer) are separate outcomes with separate messages.
        if installed { finalState = .installedPendingRestart(version: version) }
        onWegaState(WegaState(
            pose: .happy,
            line: SelfUpdatePresentation.message(for: installed ? .installed : .opened)
        ))
    }
}
