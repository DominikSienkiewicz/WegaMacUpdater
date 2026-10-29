import Foundation
import Testing

/// The "Nic nie zainstalowano" banner told the user what to type —
/// "pomoże brew reinstall --cask discord" — beside a button that runs exactly that. A banner
/// must not ask for a terminal when it carries the remedy itself, and when the reinstall has
/// already run it must point somewhere useful instead of at a command that just failed.
@Suite("Not-upgraded banner points at its button, not at a terminal")
struct NotUpgradedBannerWordingTests {
    @Test func theBannerNeverAsksTheUserToTypeACommand() throws {
        let branch = try notUpgradedBranch()
        #expect(!branch.contains("pomoże brew reinstall"),
                "the button runs the reinstall; the text must not send the user to a terminal")
    }

    @Test func theRepairOfferNamesTheButtonThatRunsIt() throws {
        let branch = try notUpgradedBranch()
        let offer = try #require(branch.range(of: "action = .reinstallCask(token: token)"))
        #expect(branch[..<offer.lowerBound].contains("„Przeinstaluj przez Brew”"))
    }

    @Test func aReinstallThatInstalledNothingPointsAtTheLog() throws {
        let branch = try notUpgradedBranch()
        let fallback = try #require(branch.range(of: "} else {"))
        #expect(branch[fallback.lowerBound...].contains("action = .openLogs"))
    }

    private func notUpgradedBranch() throws -> Substring {
        let text = try ScanStoreSources.everything()
        let start = try #require(text.range(of: "case .notUpgraded:\n            title = tr(\"Nic nie zainstalowano\")"))
        let rest = text[start.lowerBound...]
        let end = try #require(rest.range(of: "case .replacedByAppUpdater"))
        return rest[..<end.lowerBound]
    }
}
