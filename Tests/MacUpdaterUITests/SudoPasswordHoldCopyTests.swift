import Foundation
@testable import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// Owner decision 2026-11-21 — what Wega says while it asks for no administrator password: before
/// the run, on the summary's row, in the failure banner and on the Touch ID card itself.
@Suite("Sudo password hold — what Wega says") @MainActor
struct SudoPasswordHoldCopyTests {
    private static func entry(held: Bool, verdict: ItemUpdateVerdict? = nil) -> UpdateRunReportEntry {
        UpdateRunReportEntry(key: "c:zoom", name: "zoom", kind: .cask, from: "1", to: "2", verdict: verdict,
                             wasSkipped: false, wasHeldForPassword: held, checkAnswer: .confirmed,
                             appPath: nil, undoneTo: nil, publisherSettled: false)
    }

    // MARK: The summary's row

    @Test func aHeldRowOffersTheTouchIDCard() {
        #expect(Self.entry(held: true).pointsAtTouchIDCard)
        #expect(Self.entry(held: true, verdict: .executionFailed).pointsAtTouchIDCard, "the App Store batch that mas refused")
        #expect(!Self.entry(held: false).pointsAtTouchIDCard)
        #expect(!Self.entry(held: true, verdict: .succeeded).pointsAtTouchIDCard, "updated after all: nothing to point at")
        withLanguage(.en) { #expect(tr("Otwórz kartę Touch ID") == "Open Touch ID card") }
    }

    // MARK: Before the run

    @Test func theListSaysBeforeTheRunWhatWillBeSkipped() {
        let closed = PasswordPromptNotice.Probe(installed: true, touchID: .enabled, sudoDistrust: .noProofOfSafety)
        #expect(PasswordPromptNotice.holdsPrompts(probe: closed, queuedNeedingPassword: ["zoom"]))
        #expect(!PasswordPromptNotice.holdsPrompts(probe: closed, queuedNeedingPassword: []))
        #expect(!PasswordPromptNotice.holdsPrompts(probe: PasswordPromptNotice.Probe(installed: true, touchID: .enabled),
                                                    queuedNeedingPassword: ["zoom"]))
        #expect(!PasswordPromptNotice.holdsPrompts(probe: nil, queuedNeedingPassword: ["zoom"]), "an unprobed state says nothing")
        withLanguage(.pl) {
            #expect(PasswordPromptNotice.heldMessage(names: ["zoom", "parallels"])
                    == "Dopóki ustawieniom, które czyta sudo, nie można ufać, nie poproszę o hasło administratora, więc pominę zoom, parallels. Co zrobić, mówi karta Touch ID w Ustawieniach.")
        }
        withLanguage(.en) {
            #expect(PasswordPromptNotice.heldMessage(names: ["zoom"])
                    == "Until the settings sudo reads can be trusted, I won't ask for the administrator password, so I'll skip zoom. The Touch ID card in Settings says what to do.")
        }
    }

    // MARK: The failure banner

    @Test func aSudoFailureWhileTheGateIsClosedPointsAtTheCardNotAtTouchID() async {
        let formula = "sudo-held-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner(
            run: { request in
                switch request.arguments {
                case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                    let json = #"{"formulae":[{"name":"\#(formula)","installed_versions":["1"],"current_version":"2"}],"casks":[]}"#
                    return ProcessResult(exitCode: 0, stdout: json, stderr: "")
                case ["outdated"]:
                    return ProcessResult(exitCode: 0, stdout: "", stderr: "")
                default:
                    return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
                }
            },
            events: { _ in
                .success([
                    .stderr("sudo: a password is required\nError: \(formula): install failed\n"),
                    .finished(ProcessResult(exitCode: 1, stdout: "", stderr: "")),
                ])
            }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner, sudoPolicyDistrust: { .noProofOfSafety })
        harness.store.brewOutdated = BrewOutdated(
            formulae: [BrewOutdatedItem(name: formula, installedVersions: ["1"], currentVersion: "2")], casks: [])

        await withLanguage(.pl) {
            await harness.store.runUpdate(targetKeys: [UpdatePlanner.key(name: formula, kind: .formula)])
        }

        let banner = harness.store.banner
        #expect(banner?.action == .openSettings, "the action opens the Touch ID card")
        #expect(banner?.message.contains("nie można teraz ufać") == true)
        #expect(banner?.message.contains("Włącz Touch ID") == false)
        withLanguage(.en) {
            #expect(trf("%@ Cask wymaga hasła administratora, a ustawieniom, które czyta sudo, nie można teraz ufać, więc o nie nie poprosiłam. Co zrobić, mówi karta Touch ID w Ustawieniach.", "zoom:")
                    == "zoom: The cask needs the administrator password, and the settings sudo reads can't be trusted right now, so I didn't ask for it. The Touch ID card in Settings says what to do.")
        }
    }
}
