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

    @Test func thePlanSpeaksInTheFutureAboutChecksums() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
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
