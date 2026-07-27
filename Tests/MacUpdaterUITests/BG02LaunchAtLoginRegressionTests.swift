import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// BG-02 — the menu-bar agent (schedule, badge, notifications, silent updates) lives only
/// inside the running process, so before this card the whole background mode died at the
/// first restart of the Mac. The fix registers the app itself as a login item via
/// `SMAppService.mainApp`, with an explicit Settings toggle that reads the *real* system
/// status and can turn it off. The clean-system runtime behaviour cannot be exercised in
/// CI, so these source-inspection guards pin the structural facts the card requires.
@Suite("BG-02 launch-at-login regressions")
struct BG02LaunchAtLoginRegressionTests {
    @Test func sourcesRegisterTheMainAppAsALoginItemViaSMAppService() throws {
        let service = try executableSource(source("Sources/MacUpdaterCore/LoginItemService.swift"))
        #expect(
            service.contains("SMAppService.mainApp"),
            "the login item must be driven by SMAppService.mainApp (BG-02), not a legacy login-item API"
        )
        #expect(service.contains("func register()"), "the service must expose registration")
        #expect(service.contains("unregister()"), "the service must expose unregistration (disable)")
    }

    @Test func settingsExposeAnExplicitToggleReadingTheRealSystemStatus() throws {
        let card = try executableSource(source("Sources/MacUpdater/LaunchAtLoginSettingsCard.swift"))
        #expect(card.contains("Toggle"), "Settings must expose an explicit Launch-at-login toggle")
        #expect(
            card.contains("controller.state.isOn"),
            "the toggle must reflect the real login-item status, not a stored preference"
        )

        // The card is actually mounted in the Settings surface (InfoView backs the ⌘, scene).
        let info = try executableSource(source("Sources/MacUpdater/InfoView.swift"))
        #expect(
            info.contains("LaunchAtLoginSettingsCard()"),
            "the Launch-at-login card must be present in the Settings body"
        )
    }

    @Test func theControllerDerivesItsStateFromTheLiveSMAppServiceStatus() throws {
        let controller = try executableSource(source("Sources/MacUpdater/LaunchAtLoginController.swift"))
        #expect(
            controller.contains("LoginItemState(status: service.status)"),
            "the controller must derive its state from the live login-item status, not cache it"
        )
    }

    private func source(_ path: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Drops whole-line comments so a string only *mentioned* in a doc comment cannot make
    /// a structural guard pass — the same approach `ArchitectureReviewRegressionTests` uses.
    private func executableSource(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
