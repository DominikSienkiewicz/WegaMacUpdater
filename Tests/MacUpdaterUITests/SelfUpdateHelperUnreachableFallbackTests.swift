import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// A helper that cannot be reached throws before anything is submitted, so no installation is
/// pending. The verified package must then be handed to Installer.app, as v0.4.0 did, instead of
/// leaving the user with no way to update.
@Suite("Self-update when the helper is unreachable")
@MainActor
struct SelfUpdateHelperUnreachableFallbackTests {
    private struct HelperHandshakeTimedOut: Error {}

    private let asset = ReleaseAsset(name: "Wega.pkg", url: URL(fileURLWithPath: "/tmp/Wega.pkg"))

    @Test func unreachableHelperOpensTheVerifiedPackageInstead() async {
        let probe = HelperFallbackProbe()
        let controller = controller(probe, pendingAfterFailure: false)

        await controller.apply(.install(pkg: asset), version: "3.0") { probe.lastMessage = $0 }

        #expect(probe.opened == [.downloadAndOpen(asset: asset)])
        #expect(probe.openedPaths == [probe.verifiedPackage])
        #expect(controller.state == .idle)
        #expect(probe.lastMessage == WegaState(pose: .happy, line: SelfUpdatePresentation.message(for: .opened)))
        #expect(!probe.openedReleasePage)
    }

    @Test func pendingHelperInstallationNeverOpensASecondInstaller() async {
        let probe = HelperFallbackProbe()
        let controller = controller(probe, pendingAfterFailure: true)

        await controller.apply(.install(pkg: asset), version: "3.0") { probe.lastMessage = $0 }

        #expect(probe.opened.isEmpty)
        #expect(controller.state == .installationUncertain)
        #expect(probe.lastMessage?.pose == .alert)
        #expect(!probe.openedReleasePage)
    }

    private func controller(_ probe: HelperFallbackProbe, pendingAfterFailure: Bool) -> SelfUpdateController {
        SelfUpdateController(dependencies: .init(
            check: { .upToDate },
            download: { _ in probe.verifiedPackage },
            verify: { _, _ in },
            installOrOpen: { action, destination in
                probe.opened.append(action)
                probe.openedPaths.append(destination)
                return false
            },
            openFallback: { probe.openedReleasePage = true }, relaunch: {}, isBusy: { false },
            fetchHistory: { _ in .unavailable },
            installTracked: { _, _ in
                probe.pending = pendingAfterFailure
                throw HelperHandshakeTimedOut()
            },
            hasPendingInstallation: { probe.pending }
        ), upgrades: UpgradeCoordinator(operations: OperationCoordinator()))
    }
}

@MainActor
private final class HelperFallbackProbe {
    let verifiedPackage = URL(fileURLWithPath: "/tmp/Wega-verified.pkg")
    var pending = false
    var opened: [SelfUpdateAction] = []
    var openedPaths: [URL] = []
    var openedReleasePage = false
    var lastMessage: WegaState?
}
