import Foundation
import Testing
import MacUpdaterCore
import WegaHelperKit
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

    /// Z14, design review R8: the helper serves no copy that fails the bundle gate, so a copy that is
    /// refused can neither check a pending installation nor settle it. Changes stay blocked, and the
    /// state sends the user to the copy installed from the .pkg instead of to Settings.
    @Test func aRefusedCopyWithAPendingInstallationSendsTheUserToThePkgCopy() async {
        let probe = UncertainInstallationProbe()
        probe.pending = true
        let controller = refusedCopyController(probe)
        #expect(controller.pendingInstallationNeedsInstalledCopy)

        await controller.reconcileInstallation { probe.lastMessage = $0 }

        #expect(controller.state == .installationUncertain)
        #expect(controller.pendingInstallationNeedsInstalledCopy)
        #expect(probe.lastMessage?.pose == .alert)
        #expect(probe.lastMessage?.line == Self.openThePkgCopy)
        await controller.apply(.install(pkg: Self.asset), version: "3.0") { probe.lastMessage = $0 }
        #expect(probe.lastMessage?.line == Self.openThePkgCopy)
        #expect(probe.downloads == 0)
        #expect(SelfUpdatePresentation.uncertainInstallationDetail(fromRefusedCopy: true) == Self.openThePkgCopy)
        withLanguage(.en) {
            #expect(SelfUpdatePresentation.uncertainInstallationDetail(fromRefusedCopy: true)
                == "This copy of Wega can't use the helper, so it can't check this installation. Quit it and open the Wega installed from the .pkg in the /Applications folder. Until then, further changes are blocked.")
        }
    }

    @Test func aTrustedCopyKeepsTheUsualUncertainState() async {
        let probe = UncertainInstallationProbe()
        probe.pending = true
        let controller = refusedCopyController(probe, trust: .trusted)

        await controller.reconcileInstallation { probe.lastMessage = $0 }

        #expect(controller.state == .installationUncertain)
        #expect(!controller.pendingInstallationNeedsInstalledCopy)
        #expect(probe.lastMessage?.line
            == "Wynik instalacji jest nieznany. Dalsze zmiany są zablokowane — sprawdź stan instalacji w Ustawieniach.")
        #expect(SelfUpdatePresentation.uncertainInstallationDetail(fromRefusedCopy: false)
            == "Instalator może nadal działać. Dalsze zmiany są zablokowane; nie uruchamiaj drugiego instalatora.")
    }

    /// Without a pending installation there is nothing to send the user anywhere for.
    @Test func aRefusedCopyWithoutAPendingInstallationIsNotSentAnywhere() {
        let controller = refusedCopyController(UncertainInstallationProbe())

        #expect(controller.state == .idle)
        #expect(!controller.pendingInstallationNeedsInstalledCopy)
    }

    /// The Settings row is not unit tested, so its wiring is pinned.
    @Test func theSettingsRowReadsTheController() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let info = try String(contentsOf: root.appendingPathComponent("Sources/MacUpdater/InfoView.swift"), encoding: .utf8)
            .filter { !$0.isWhitespace }
        #expect(info.contains("Text(SelfUpdatePresentation.uncertainInstallationDetail(fromRefusedCopy:selfUpdateController.pendingInstallationNeedsInstalledCopy))"))
        let controller = try String(contentsOf: root.appendingPathComponent("Sources/MacUpdater/SelfUpdateController.swift"), encoding: .utf8)
            .filter { !$0.isWhitespace }
        #expect(controller.contains("bundleTrust:{PrivilegedHelperClient.shared.bundleTrust}"))
    }

    private static let asset = ReleaseAsset(name: "Wega.pkg", url: URL(fileURLWithPath: "/tmp/Wega.pkg"))
    private static let openThePkgCopy = "Ta kopia Wegi nie może używać pomocnika, więc nie sprawdzi tej instalacji. Zakończ ją i otwórz Wegę zainstalowaną z pakietu .pkg w folderze /Applications. Do tego czasu dalsze zmiany są zablokowane."

    /// A copy whose every helper call fails, as `HelperPackageInstallation.reconcile` reports it.
    private func refusedCopyController(
        _ probe: UncertainInstallationProbe, trust: HelperBundleTrust = .refused(.notInApplications)
    ) -> SelfUpdateController {
        SelfUpdateController(dependencies: .init(
            check: { .upToDate },
            download: { url in await probe.downloaded(); return url },
            verify: { _, _ in },
            installOrOpen: { _, _ in false },
            openFallback: { probe.openedFallback = true }, relaunch: {}, isBusy: { false },
            fetchHistory: { _ in .unavailable },
            hasPendingInstallation: { probe.pending },
            reconcileInstallation: { throw HelperPackageInstallation.Failure.outcomeUnknown(operationID: probe.id) },
            bundleTrust: { trust }
        ), upgrades: UpgradeCoordinator(operations: OperationCoordinator()))
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
