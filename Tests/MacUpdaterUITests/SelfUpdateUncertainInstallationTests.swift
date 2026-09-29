import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Self-update with an unknown installer outcome")
@MainActor
struct SelfUpdateUncertainInstallationTests {
    @Test func lostReplyDoesNotOpenAnotherInstallerOrAllowAnotherDownload() async {
        let probe = UncertainInstallationProbe()
        let controller = controller(probe)
        let asset = ReleaseAsset(name: "Wega.pkg", url: URL(fileURLWithPath: "/tmp/Wega.pkg"))
        await controller.apply(.install(pkg: asset), version: "3.0") { probe.lastMessage = $0 }
        #expect(controller.state == .installationUncertain)
        #expect(!controller.canRestart)
        #expect(!probe.openedFallback)
        #expect(probe.lastMessage?.pose == .alert)
        await controller.apply(.install(pkg: asset), version: "3.0") { _ in }
        await controller.check()
        #expect(probe.downloads == 1)
        #expect(controller.state == .installationUncertain)
    }

    @Test func reopeningTheControllerOffersReconciliationInsteadOfAnUpdate() async {
        let probe = UncertainInstallationProbe()
        probe.pending = true
        let controller = controller(probe)
        #expect(controller.state == .installationUncertain)
        await controller.reconcileInstallation { _ in }
        #expect(controller.state == .installedPendingRestart(version: "3.0"))
        #expect(probe.downloads == 0)
        #expect(!probe.pending)
        #expect(controller.canRestart)
    }

    private func controller(_ probe: UncertainInstallationProbe) -> SelfUpdateController {
        SelfUpdateController(dependencies: .init(
            check: { .upToDate },
            download: { url in await probe.downloaded(); return url },
            verify: { _, _ in },
            installOrOpen: { _, _ in
                probe.pending = true
                throw HelperPackageInstallation.Failure.outcomeUnknown(operationID: probe.id)
            },
            openFallback: { probe.openedFallback = true }, relaunch: {}, isBusy: { false },
            fetchHistory: { _ in .unavailable },
            hasPendingInstallation: { probe.pending },
            reconcileInstallation: {
                probe.pending = false
                return PendingHelperInstallation(operationID: probe.id, version: "3.0")
            }
        ), upgrades: UpgradeCoordinator(operations: OperationCoordinator()))
    }
}

@MainActor
private final class UncertainInstallationProbe {
    let id = UUID()
    var pending = false
    var downloads = 0
    var openedFallback = false
    var lastMessage: WegaState?
    func downloaded() { downloads += 1 }
}
