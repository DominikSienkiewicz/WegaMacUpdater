import Foundation
import Testing
@testable import MacUpdaterCore

/// "Przeinstaluj przez Brew" — the button on the "Nic nie zainstalowano" banner. An adoption
/// whose `install --force` exited 0 without touching the disk (Discord 0.0.412: "Not upgrading
/// discord, the latest version is already installed") used to end on a banner telling the user
/// to type `brew reinstall --cask discord` themselves. The banner now runs it.
@Suite("Reinstall cask from the not-upgraded banner")
struct BrewCaskReinstallTests {
    @Test func reinstallArgumentsReinstallTheCaskWithTheTokenFenced() {
        // SEC-10: `--` fences the token off from Homebrew's option parsing.
        #expect(BrewService.reinstallCaskArguments(token: "discord") == ["reinstall", "--cask", "--", "discord"])
    }

    @Test func reinstallRunsThroughTheProtectedAdoptionFlow() throws {
        let text = try ScanStoreSources.everything()
        let entry = try #require(text.range(of: "func reinstallManual(token: String) async"))
        let body = text[entry.lowerBound...].prefix(400)

        #expect(body.contains("performWrite(.manualInstall)"))
        #expect(body.contains("installManualCoordinated(token: token, installArgs: BrewService.reinstallCaskArguments(token: token))"),
                "the repair must reuse the snapshot → verify → rollback transaction, not call brew directly")
    }

    @Test func notUpgradedBannerOffersTheReinstallUnlessItWasTheReinstall() throws {
        let text = try ScanStoreSources.everything()
        let start = try #require(text.range(of: "case .notUpgraded:\n            title = tr(\"Nic nie zainstalowano\")"))
        let branch = text[start.lowerBound...].prefix(700)

        #expect(branch.contains("if installArgs != BrewService.reinstallCaskArguments(token: token)"))
        #expect(branch.contains("action = .reinstallCask(token: token)"))
        #expect(text.contains("showBanner(BannerData(variant: .danger, title: title, message: message, action: action))"))
    }
}
