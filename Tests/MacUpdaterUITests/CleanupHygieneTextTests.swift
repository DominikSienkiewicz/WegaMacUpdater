import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

@MainActor
final class CleanupHygieneTextTests: XCTestCase {
    private func withLanguage<T>(_ language: AppLanguage, _ body: () throws -> T) rethrows -> T {
        let previous = LocalizedStrings.current
        LocalizedStrings.current = language
        defer { LocalizedStrings.current = previous }
        return try body()
    }

    func testDeadEntryStatusIsTranslated() {
        withLanguage(.pl) { XCTAssertEqual(CleanupPresentation.statusText(.deadEntry), "martwy wpis") }
        XCTAssertEqual(Translations.en["martwy wpis"], "dead entry")
    }

    func testDetectorNamesAreTranslated() {
        XCTAssertEqual(Translations.en["higiena PATH"], "PATH hygiene")
        XCTAssertEqual(Translations.en["mapa „Pliki i foldery”"], "Files and Folders map")
    }

    func testShellFileInstructionSaysWhenTheEntryWasAddedDynamically() {
        withLanguage(.pl) {
            let dynamic = CleanupPresentation.instructionText(.editShellFiles(entry: "~/x", locations: []))
            let located = CleanupPresentation.instructionText(
                .editShellFiles(entry: "~/x", locations: [CleanupShellFileLocation(file: "~/.zshrc", line: 3)])
            )
            XCTAssertFalse(dynamic.isEmpty)
            XCTAssertNotEqual(dynamic, located)
            XCTAssertTrue(located.contains("~/.zshrc:3"), located)
        }
    }

    func testSwitchOffInstructionNamesTheSettingsPane() {
        withLanguage(.pl) {
            XCTAssertTrue(CleanupPresentation.instructionText(.switchOffInFilesAndFolders).contains("Pliki i foldery"))
        }
    }

    func testEveryNewNoteKindHasText() {
        for kind in [CleanupDetectorNote.Kind.tccUnreadable, .tccUnsupportedSchema, .tccMapEmpty] {
            let text = CleanupPresentation.noteText(CleanupDetectorNote(detector: .tccMap, kind: kind))
            XCTAssertFalse(text.isEmpty, "\(kind)")
        }
    }

    func testEveryNewReasonHasTextInBothLanguages() {
        let reasons: [CleanupReason] = [
            .missingPathEntry, .repeatedPathEntry(count: 2), .samePlaceAs(path: "~/a"), .nestedIn(parent: "~/b"),
            .olderCopyWins(version: "1.0.0", newer: "~/n", newerVersion: "2.0.0"),
            .tccEntry(grants: [CleanupTCCGrant(service: .documents, allowed: true)], link: nil),
            .tccEntryFileGone(grants: [CleanupTCCGrant(service: .downloads, allowed: false)]),
        ]
        for reason in reasons {
            let polish = withLanguage(.pl) { CleanupPresentation.reasonText(reason) }
            let english = withLanguage(.en) { CleanupPresentation.reasonText(reason) }
            XCTAssertFalse(polish.isEmpty, "\(reason)")
            XCTAssertNotEqual(polish, english, "\(reason)")
        }
    }
}
