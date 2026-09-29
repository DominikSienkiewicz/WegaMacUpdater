import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Self-update binds installation to the offered version")
@MainActor
struct SelfUpdateExpectedVersionTests {
    @Test func anUnversionedLiveInstallIsRefusedBeforeContactingTheHelper() async {
        let asset = ReleaseAsset(name: "Wega.pkg", url: URL(fileURLWithPath: "/tmp/Wega.pkg"))
        await #expect(throws: PackagePayloadVerifier.Failure.self) {
            try await SelfUpdateController.Dependencies.live.installOrOpen(.install(pkg: asset), asset.url)
        }
    }

    @Test func offeredVersionReachesTheTrackedInstallerAndRestartState() async {
        let asset = ReleaseAsset(name: "Wega.pkg", url: URL(fileURLWithPath: "/tmp/Wega.pkg"))
        let probe = InstalledVersionProbe()
        let controller = SelfUpdateController(dependencies: .init(
            check: { .updateAvailable(version: "3.0", assets: [asset], releaseURL: asset.url, notes: "") },
            download: { $0 }, verify: { _, version in #expect(version == "3.0") },
            installOrOpen: { _, _ in Issue.record("Tracked installs must keep their version"); return false },
            openFallback: {}, relaunch: {}, isBusy: { false }, fetchHistory: { _ in .unavailable },
            installTracked: { _, version in probe.version = version; return true }
        ))
        await controller.check()
        await controller.apply(.install(pkg: asset), version: "2.0") { _ in }
        #expect(probe.version == "3.0")
        #expect(controller.state == .installedPendingRestart(version: "3.0"))
    }

    @Test func explicitTargetIsVerifiedWhenNoEarlierCheckExists() async {
        let asset = ReleaseAsset(name: "Wega.pkg", url: URL(fileURLWithPath: "/tmp/Wega.pkg"))
        let controller = SelfUpdateController(dependencies: .init(
            check: { .upToDate }, download: { $0 }, verify: { _, version in #expect(version == "3.0") },
            installOrOpen: { _, _ in false }, openFallback: {}, relaunch: {}, isBusy: { false },
            fetchHistory: { _ in .unavailable }
        ))
        await controller.apply(.install(pkg: asset), version: "3.0") { _ in }
    }
}

@MainActor
private final class InstalledVersionProbe {
    var version: String?
}
