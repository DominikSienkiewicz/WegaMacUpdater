import Testing
import Foundation
@testable import MacUpdaterCore
@testable import WegaMacUpdater

/// A headless `.pkg` install swaps the bundle under a live process. The install therefore ends
/// in an explicit terminal state that asks for a restart — it never restarts on its own, and it
/// never restarts while another mutating operation holds the write gate.
@MainActor
@Suite("SelfUpdate restart")
struct SelfUpdateRestartTests {
    private func pkg() -> ReleaseAsset {
        ReleaseAsset(name: "Wega.pkg", url: URL(string: "https://example.com/Wega.pkg")!)
    }

    private func dependencies(
        installed: Bool,
        busy: Bool = false,
        relaunched: @escaping @MainActor @Sendable () -> Void = {}
    ) -> SelfUpdateController.Dependencies {
        SelfUpdateController.Dependencies(
            check: { .upToDate },
            download: { $0 },
            verify: { _ in },
            installOrOpen: { _, _ in installed },
            openFallback: {},
            relaunch: relaunched,
            isBusy: { busy },
            fetchHistory: { _ in .unavailable }
        )
    }

    @Test func headlessInstallEndsAskingForARestart() async {
        let controller = SelfUpdateController(dependencies: dependencies(installed: true))

        await controller.apply(.install(pkg: pkg()), version: "1.0.1") { _ in }

        #expect(controller.state == .installedPendingRestart(version: "1.0.1"))
    }

    /// The user finishes a `.dmg` by hand, so there is nothing installed to restart into.
    @Test func openingAnInstallerDoesNotAskForARestart() async {
        let controller = SelfUpdateController(dependencies: dependencies(installed: false))

        await controller.apply(.downloadAndOpen(asset: pkg()), version: "1.0.1") { _ in }

        #expect(controller.state != .installedPendingRestart(version: "1.0.1"))
    }

    @Test func restartIsRefusedWhileAMutatingOperationRuns() async {
        var relaunches = 0
        let controller = SelfUpdateController(
            dependencies: dependencies(installed: true, busy: true, relaunched: { relaunches += 1 })
        )
        await controller.apply(.install(pkg: pkg()), version: "1.0.1") { _ in }

        #expect(controller.canRestart == false)
        controller.restart()
        #expect(relaunches == 0)
    }

    @Test func restartRunsWhenNothingElseIsMutating() async {
        var relaunches = 0
        let controller = SelfUpdateController(
            dependencies: dependencies(installed: true, relaunched: { relaunches += 1 })
        )
        await controller.apply(.install(pkg: pkg()), version: "1.0.1") { _ in }

        #expect(controller.canRestart)
        controller.restart()
        #expect(relaunches == 1)
    }
}
