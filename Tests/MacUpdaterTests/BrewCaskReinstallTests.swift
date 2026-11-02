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
        let traced = try #require(text.range(of: "private func reinstallManualTraced(token: String) async"))
        let coordinated = try #require(text.range(of: "private func installManualCoordinated(token: String, installArgs: [String]) async"))
        try #require(entry.lowerBound < traced.lowerBound && traced.lowerBound < coordinated.lowerBound)
        let entryBody = text[entry.lowerBound..<traced.lowerBound]
        let tracedBody = text[traced.lowerBound..<coordinated.lowerBound]

        #expect(entryBody.contains("await reinstallManualTraced(token: token)"))
        let writeGate = try #require(tracedBody.range(of: "performWrite(.manualInstall)"))
        let transaction = try #require(tracedBody.range(of:
            "installManualCoordinated(token: token, installArgs: BrewService.reinstallCaskArguments(token: token))"
        ))
        #expect(writeGate.lowerBound < transaction.lowerBound,
                "the repair must enter the write gate before reusing the snapshot → verify → rollback transaction")
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
