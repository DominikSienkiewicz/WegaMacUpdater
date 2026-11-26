import MacUpdaterCore
import XCTest

final class StorageFeatureTranslationTests: XCTestCase {
    func testEachStorageReviewCanBeFoundByItsEnglishLabel() {
        XCTAssertEqual(Translations.en["Sprawdź miejsce ponownie"], "Check space again")
        XCTAssertEqual(Translations.en["Duże i dawno nieotwierane"], "Large and last opened 90+ days ago")
        XCTAssertEqual(Translations.en["Zmiana od pomiaru"], "Change since last measurement")
        XCTAssertEqual(Translations.en["Środowiska symulatorów"], "Simulator runtimes")
    }
}
