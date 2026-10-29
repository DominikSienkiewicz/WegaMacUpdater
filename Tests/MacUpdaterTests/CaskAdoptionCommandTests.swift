import Foundation
import Testing
@testable import MacUpdaterCore

/// "Aktualizuj przez Brew" on a cask whose Caskroom already records the version the row offers.
///
/// Discord, 2026-10-27/29: Homebrew recorded `0.0.420`, `/Applications/Discord.app` was `0.0.419`.
/// `brew install --cask --force` answered "Not upgrading discord, the latest version is already
/// installed", wrote nothing, and the user got "Nic nie zainstalowano" with a button to run the
/// reinstall by hand — every time Discord's own updater had put the older build back. The repair
/// was always the same command, so the update now runs it straight away.
@Suite("Adoption reinstalls when Homebrew already records the offered version")
struct CaskAdoptionCommandTests {
    @Test func recordAlreadyAtTheOfferReinstallsInsteadOfANoOpForceInstall() {
        // Given Homebrew's record already names the version the row offers
        // When the update picks its brew command
        // Then it reinstalls, because `install --force` would write nothing
        #expect(
            CaskAdoptionCommand.arguments(token: "discord", offeredVersion: "0.0.420", recordedVersion: "0.0.420")
                == BrewService.reinstallCaskArguments(token: "discord")
        )
    }

    @Test func appHomebrewDoesNotTrackIsAdoptedWithForce() {
        // Given an app Homebrew has no record of (Docker installed from its own DMG)
        // When the update picks its brew command
        // Then it adopts it with `install --force`, the only command that takes over the bundle
        #expect(
            CaskAdoptionCommand.arguments(token: "docker-desktop", offeredVersion: "4.97.0", recordedVersion: nil)
                == BrewService.adoptCaskArguments(token: "docker-desktop")
        )
    }

    @Test func recordBehindTheOfferIsAnOrdinaryUpgrade() {
        // Given Homebrew records an older version than the row offers
        // When the update picks its brew command
        // Then `install --force` stays: it really does install the new version
        #expect(
            CaskAdoptionCommand.arguments(token: "discord", offeredVersion: "0.0.420", recordedVersion: "0.0.419")
                == BrewService.adoptCaskArguments(token: "discord")
        )
    }

    @Test func rowWithoutAnOfferedVersionKeepsTheAdoption() {
        // Given a row that does not say which version it offers
        // When the update picks its brew command
        // Then nothing proves the record is ahead, so the adoption is left as it was
        #expect(
            CaskAdoptionCommand.arguments(token: "discord", offeredVersion: nil, recordedVersion: "0.0.420")
                == BrewService.adoptCaskArguments(token: "discord")
        )
    }

    @Test func manualUpdateAsksHomebrewForItsRecordBeforeChoosingTheCommand() throws {
        let text = try ScanStoreSources.everything()
        let entry = try #require(text.range(of: "private func installManualCoordinated(token: String, installArgs: [String]) async"))
        let body = text[entry.lowerBound...]
        let mutation = try #require(body.range(of: "model.brewService.events(arguments: installArgs)"))
        let head = body[..<mutation.lowerBound]

        let record = try #require(head.range(of: "model.brewService.caskInstalledVersions()"))
        let choice = try #require(head.range(of: "CaskAdoptionCommand.arguments("))
        let logLine = try #require(head.range(of: "brewLog = [\"$ brew \" + installArgs.joined(separator: \" \")]"))
        #expect(record.lowerBound < choice.lowerBound)
        #expect(choice.lowerBound < logLine.lowerBound,
                "the log must name the command that actually runs, not the one that was requested")
    }
}
