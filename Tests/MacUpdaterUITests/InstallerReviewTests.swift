import AppKit
import SwiftUI
import XCTest
@testable import WegaMacUpdater

@MainActor
final class InstallerReviewTests: XCTestCase {
    func testInitialReviewFitsTheSingleFolderChooserHero() {
        withLanguage(.pl) {
            let review = CleanupFileReviewView(page: .installers, search: "", store: CleanupFileReviewStore())
            let hero = EmptyHero(title: "Przejrzyj stare instalatory",
                                 message: "Wybierz folder, np. Pobrane. Wega pokaże instalatory, których nie zmieniano od co najmniej 30 dni.",
                                 action: AnyView(Button {} label: { Label("Wybierz folder…", systemImage: "folder") }
                                     .buttonStyle(.borderedProminent).controlSize(.large)), compact: true)
            for width in [CGFloat(410), 700] {
                let actual = NSHostingView(rootView: review.frame(width: width)).fittingSize
                let expected = NSHostingView(rootView: hero.frame(width: width)).fittingSize
                XCTAssertEqual(actual.height, expected.height, accuracy: 2)
            }
        }
    }

    func testFolderSummaryAddsTheSizesOfEveryInstaller() {
        withLanguage(.pl) {
            let summary = InstallerReviewSummary.text(sizes: [340_000_000, 180_000_000, 100_000_000])
            XCTAssertEqual(summary.split(whereSeparator: \.isWhitespace).joined(separator: " "), "3 instalatory · 620 MB")
            XCTAssertEqual(InstallerReviewSummary.text(sizes: [.max, 1]), "2 instalatory")
        }
    }

    func testOnlyTheExpandedFileAddsDetailsAtBothWindowWidths() {
        let names = ["LibreOffice.dmg", "Firefox.dmg", "Zoom.pkg"]
        func height(_ files: [String], expanded: String?, width: CGFloat) -> CGFloat {
            let view = VStack(spacing: 0) {
                ForEach(files, id: \.self) { name in
                    CleanupInstallerRow(url: URL(filePath: "/example/" + name, directoryHint: .notDirectory),
                                        size: 100_000_000, modified: .distantPast, installedVersion: nil,
                                        expanded: .constant(name == expanded), onReveal: {}, onTrash: {})
                }
            }
            return NSHostingView(rootView: view.frame(width: width)).fittingSize.height
        }
        for width in [CGFloat(320), 700] {
            let change = height(names, expanded: names[1], width: width) - height(names, expanded: nil, width: width)
            let oneRow = height([names[1]], expanded: names[1], width: width) - height([names[1]], expanded: nil, width: width)
            XCTAssertGreaterThan(change, 40)
            XCTAssertEqual(change, oneRow, accuracy: 2)
        }
    }

    func testInstallerCountUsesTheChosenLanguageAndPolishPluralForms() {
        withLanguage(.pl) {
            XCTAssertEqual([0, 1, 3, 12, 22].map { trp("%@ instalatorów", $0) },
                           ["0 instalatorów", "1 instalator", "3 instalatory", "12 instalatorów", "22 instalatory"])
        }
        withLanguage(.en) {
            XCTAssertEqual([1, 3].map { trp("%@ instalatorów", $0) }, ["1 installer", "3 installers"])
        }
    }
}
