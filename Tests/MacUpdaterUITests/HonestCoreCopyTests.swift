import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Honest core copy") @MainActor
struct HonestCoreCopyTests {
    @Test func postponeReasonsSpeakEnglishInEnglish() {
        LocalizedStrings.withScopedLanguage(.en) {
            #expect(PostponeReason.lowBattery.localizedMessage == "Battery is low. Connect power and try again.")
            #expect(PostponeReason.insufficientDisk(required: 2_000_000_000, available: 0).localizedMessage
                .hasPrefix("Not enough space: about "))
            #expect(!PostponeReason.meteredNetwork.localizedMessage.contains("taryfowe"))
        }
    }

    @Test func postponeReasonsGiveAnOwnNextStepInPolish() {
        LocalizedStrings.withScopedLanguage(.pl) {
            #expect(PostponeReason.lowBattery.localizedMessage == "Niski poziom baterii. Podłącz zasilanie i spróbuj ponownie.")
            #expect(PostponeReason.thermal.localizedMessage == "Mac jest zbyt gorący. Poczekaj, aż ostygnie.")
            #expect(PostponeReason.lowDataMode.localizedMessage
                == "Włączony jest tryb oszczędzania danych. Wyłącz go albo użyj innej sieci.")
        }
    }

    @Test func everyPostponeReasonIsTranslated() {
        let reasons: [PostponeReason] = [
            .meteredNetwork, .lowDataMode, .thermal, .lowBattery, .diskSpaceUnknown,
            .insufficientDisk(required: 1_000_000_000, available: 1)
        ]
        LocalizedStrings.withScopedLanguage(.en) {
            for reason in reasons {
                let message = reason.localizedMessage
                #expect(!message.contains("Mac jest") && !message.contains("Niski") && !message.contains("tryb"), "\(message)")
            }
        }
    }

    /// M2 — every reason already ends in a full stop, and the log frame added a second
    /// ("…spróbuj ponownie..").
    @Test(arguments: [AppLanguage.pl, .en])
    func aPostponedRunLogsASingleFullStop(language: AppLanguage) async throws {
        let token = "oversized-cask-\(UUID().uuidString)"
        let runner = ScanStoreRuntimeProcessRunner { request in
            guard request.arguments == ["info", "--cask", "--json=v2", token] else {
                return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected")
            }
            return ProcessResult(exitCode: 0, stdout: #"{"casks":[]}"#, stderr: "")
        }
        let harness = makeScanStoreRuntimeHarness(runner: runner, resourceDecision: liveScanStoreResourceDecision)
        harness.store.brewOutdated = BrewOutdated(
            formulae: [], casks: [BrewOutdatedItem(name: token, installedVersions: ["1"], currentVersion: "2")]
        )
        harness.store.caskSizes[token] = .known(bytes: Int64.max)

        await withLanguage(language) {
            await harness.store.runUpdate(targetKeys: [UpdatePlanner.key(name: token, kind: .cask)])
        }

        let line = try #require(harness.store.brewLog.first { $0.hasPrefix("⏸") },
                                "sanity: the run was postponed — banner: \(harness.store.banner?.title ?? "none"), log: \(harness.store.brewLog)")
        #expect(!line.contains(".."), "M2: \(line)")
        #expect(line.hasSuffix("."))
    }

    @Test func noPostponeLogFrameAddsASecondFullStop() throws {
        for path in ["Sources/MacUpdater/ScanStore+Adoption.swift", "Sources/MacUpdater/ScanStore+Rollback.swift",
                     "Sources/MacUpdater/MigrationStore.swift", "Sources/MacUpdater/BackgroundUpdater.swift"] {
            let text = try source(path)
            #expect(!text.contains("localizedMessage).\""), "M2: \(path) ends a reason with a second full stop")
            #expect(!text.contains("odroczona: %@.\""), "M2: \(path) still uses the format with its own full stop")
        }
    }

    @Test func thePlanSpeaksInTheFutureAboutChecksums() throws {
        let view = try source("Sources/MacUpdater/PlanPreviewCaskRow.swift")
        #expect(view.contains("tr(\"suma zostanie sprawdzona\")"))
        #expect(!view.contains("tr(\"suma sprawdzana\")"))
    }

    @Test func askpassFollowsTheSystemLanguage() throws {
        let askpass = try source("Sources/WegaAskpass/main.swift")
        #expect(askpass.contains("Locale.preferredLanguages"))
        #expect(askpass.contains("Homebrew needs your administrator password to finish the update."))
        #expect(askpass.contains("\"Cancel\""))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }
}
