import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Service vendor handoffs remain accessible without claiming updates")
@MainActor
struct ServiceVendorHandoffTests {
    @Test func inventoryOffersTheExactInstalledAppWithoutAnyVersionCheck() {
        let app = application()
        let presentation = InventoryCheckPresentation(app: app, check: nil, policies: [:])
        #expect(presentation.serviceVendor == .cloudflareWarp)
        #expect(presentation.vendorAppURL == app.path)
        #expect(presentation.status == .notChecked)
        #expect(presentation.needsAttention)
    }

    @Test func failedStaleAndUnconfirmedEvidenceRetainsItsMeaning() {
        let app = application()
        let now = Date(timeIntervalSince1970: 100_000)
        var failed = InstallationCheck(app: app, sources: [.init(source: "Homebrew", outcome: .failed)], checkedAt: now)
        failed.unconfirmedCaskToken = "cloudflare-warp"
        let presentation = InventoryCheckPresentation(app: app, check: failed, policies: [:], now: now)
        #expect(presentation.status == .failed)
        #expect(presentation.check?.unconfirmedCaskToken == "cloudflare-warp")
        #expect(presentation.serviceVendor == .cloudflareWarp)
        let stale = InventoryCheckPresentation(app: app, check: failed, policies: [:], now: now.addingTimeInterval(90_000))
        #expect(stale.status == .stale)
    }

    @Test func brewServiceUpdateRemainsCountedButNeverEntersBatchCommands() throws {
        let store = makeScanStoreRuntimeHarness(runner: noProcesses()).store
        store.status = .results
        store.brewOutdated = .init(formulae: [], casks: [.init(name: "cloudflare-warp", installedVersions: ["1"], currentVersion: "2")])
        store.selected = ["c:cloudflare-warp"]
        #expect(store.visibleItems(for: .all).isEmpty)
        #expect(store.updateTargets(for: .all).isEmpty)
        #expect(store.plannedCommands(targetKeys: store.selected).isEmpty)
        #expect(store.plannedCaskTokens(targetKeys: store.selected).isEmpty)
        #expect(store.updateCount == UnifiedUpdateCount(installable: 0, manual: 1))
        let app = application()
        store.caskIconPaths = ["cloudflare-warp": app.path]
        store.installationChecks = [InstallationCheck(app: app, sources: [], checkedAt: Date())]
        let row = try #require(store.visibleManual.first)
        #expect(row.path == app.path)
        #expect(store.updateCount == UnifiedUpdateCount(installable: 0, manual: 1))
        store.inspectedKey = "c:cloudflare-warp"
        #expect(store.inspectedUpdate == .manual(row))
    }

    @Test func openingTheVendorDoesNotConfirmAnUpdateOrAddAnInventedTarget() {
        let store = makeScanStoreRuntimeHarness(runner: noProcesses()).store
        #expect(store.visibleManual.isEmpty)
        #expect(store.updateCount == UnifiedUpdateCount(installable: 0, manual: 0))
        let app = application()
        let item = ManualOutdatedApp(name: app.name, path: app.path, installedVersion: "1", availableVersion: "2",
                                    source: .cask(token: "cloudflare-warp"), origin: .brew, bundleIdentifier: app.bundleIdentifier)
        store.vendorOpened(item, succeeded: true)
        #expect(store.vendorHandoffs == [item])
        #expect(store.installationChecks.isEmpty)
    }

    private func application() -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Cloudflare WARP.app"), name: "Cloudflare WARP",
                        bundleIdentifier: "com.cloudflare.1dot1dot1dot1.macos", version: "1",
                        installDate: nil, updateDate: nil, isManagedByBrew: false)
    }

    private func noProcesses() -> ScanStoreRuntimeProcessRunner {
        ScanStoreRuntimeProcessRunner { _ in
            Issue.record("A vendor handoff must not execute a package manager or change service state")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
    }
}
