import Foundation
import Testing
@testable import MacUpdaterCore

/// M9 — `Translations+RunSummary.swift` adds only keys no other section has, each with an
/// English text that keeps its placeholders.
@Suite("Run summary translations")
struct RunSummaryTranslationsTests {
    /// Every section `Translations.en` is composed from, apart from `runSummary` itself.
    private static let otherSections: [[String: String]] = [
        Translations.base, Translations.operations, Translations.vendorCompletion, Translations.rollbackScope,
        DockerRestartTranslations.english, Translations.dockerShutdown, Translations.dockerDesktop,
        Translations.unconfirmedCaskAssociation, Translations.serviceVendors, Translations.cleanup,
        Translations.cleanupHygiene, MicrosoftAutoUpdateTranslations.english, Translations.uninstallTexts,
        Translations.updatesActionBar, Translations.uxReview, Translations.uxReviewNext,
        Translations.uxReviewRest, Translations.uxNextBatch, Translations.touchIDDisable,
    ]

    @Test func everyKeyHasAnEnglishTextWithTheSamePlaceholders() {
        #expect(!Translations.runSummary.isEmpty, "sanity: the section has keys")
        for (key, english) in Translations.runSummary {
            #expect(!english.isEmpty, "\(key)")
            #expect(placeholders(in: english) == placeholders(in: key), "\(key) → \(english)")
            #expect(Translations.en[key] == english, "\(key) is merged into Translations.en")
        }
    }

    @Test func theSectionRepeatsNoKeyOfAnotherSection() {
        let elsewhere = Self.otherSections.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        let repeated = Set(Translations.runSummary.keys).intersection(elsewhere).sorted()
        #expect(repeated.isEmpty, "M9: Translations+RunSummary.swift repeats \(repeated)")
    }

    private func placeholders(in text: String) -> Int {
        text.components(separatedBy: "%@").count - 1
    }
}
