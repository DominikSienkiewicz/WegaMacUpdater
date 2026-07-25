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
                if PrivilegedHelperClient.shared.isEnabled,
                   destination.pathExtension.lowercased() == "pkg" {
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

        let destination: URL
        do {
            destination = try await dependencies.download(source)
        } catch {
            WegaLog.error(.network, "Self-update — pobieranie: \(error.localizedDescription)")
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

        if installed {
            onWegaState(WegaState(
                pose: .happy,
                line: tr("Aktualizacja zainstalowana przez komponent uprzywilejowany.")
            ))
        }
    }
}
