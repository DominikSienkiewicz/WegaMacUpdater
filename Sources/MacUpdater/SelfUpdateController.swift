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
    }

    struct Dependencies: Sendable {
        var check: @Sendable () async -> WegaSelfUpdateChecker.Result
        var download: @Sendable (URL) async throws -> URL
        var verify: @Sendable (URL) throws -> Void
        var installOrOpen: @MainActor @Sendable (URL) async -> Bool
        var openFallback: @MainActor @Sendable () -> Void

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
            installOrOpen: { destination in
                // UX-06 — the same decision the button label is built from, so "install" and
                // "download and open" always describe the operation that actually runs.
                // Wraps the already-downloaded file back into a `ReleaseAsset` for the planner's
                // new asset-list signature; Task 3 threads the real `ReleaseAsset` through here.
                let downloaded = ReleaseAsset(name: destination.lastPathComponent, url: destination)
                if case .install = SelfUpdatePlanner.action(
                    helperEnabled: PrivilegedHelperClient.shared.isEnabled,
                    assets: [downloaded]
                ) {
                    do {
                        try await PrivilegedHelperClient.shared.installVerifiedPackage(at: destination.path)
                        return true
                    } catch {
                        WegaLog.error(
                            .helper,
                            "Instalacja przez helper nie powiodła się: \(error.localizedDescription)"
                        )
                    }
                }
                NSWorkspace.shared.open(destination)
                return false
            },
            openFallback: {
                NSWorkspace.shared.open(AppEndpoints.shared.projectRepositoryURL)
            }
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
        case .idle, .checking: return nil
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

    func downloadAndOpen(
        _ source: URL,
        onWegaState: @MainActor (WegaState) -> Void
    ) async {
        guard !isDownloading else { return }
        let previousResult = result
        state = .downloading(previousResult)
        defer { state = previousResult.map(State.result) ?? .idle }

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
                return await self.dependencies.installOrOpen(destination)
            }
        } catch is CancellationError {
            return
        } catch {
            WegaLog.error(.app, "Self-update — koordynacja instalacji: \(error.localizedDescription)")
            return
        }

        // UX-06 — `install` (headless, via the helper) and `open` (the user finishes a
        // downloaded installer) are separate outcomes with separate messages.
        onWegaState(WegaState(
            pose: .happy,
            line: SelfUpdatePresentation.message(for: installed ? .installed : .opened)
        ))
    }
}
