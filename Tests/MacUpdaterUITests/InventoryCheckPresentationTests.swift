import Foundation
import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

final class InventoryCheckPresentationTests: XCTestCase {
    func testNoRecordAndARecordForAnotherCopyBothRequireChecking() {
        let app = ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                                  bundleIdentifier: "com.example.app", version: "1", installDate: nil, updateDate: nil,
                                  isManagedByBrew: false, caskToken: nil)
        let now = Date()
        var other = app
        other.path = URL(fileURLWithPath: "/Users/test/Applications/Example.app")
        let check = InstallationCheck(app: other, sources: [.init(source: "Sparkle", outcome: .current)], checkedAt: now)
        for record in [nil, check] {
            let presentation = InventoryCheckPresentation(app: app, check: record, policies: [:], now: now)
            XCTAssertEqual(presentation.status, .notChecked)
            XCTAssertNil(presentation.check)
        }
    }

    func testAnIncompleteUpdateStillShowsTheAvailableUpdateAndItsFailedSource() {
        let app = ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                                  bundleIdentifier: nil, version: "1", installDate: nil, updateDate: nil,
                                  isManagedByBrew: false, caskToken: nil)
        let now = Date()
        let check = InstallationCheck(app: app, sources: [
            .init(source: "Sparkle", outcome: .outdated, availableVersion: "2"),
            .init(source: "GitHub", outcome: .failed)
        ], checkedAt: now)
        let presentation = InventoryCheckPresentation(app: app, check: check, policies: [:], now: now)
        XCTAssertEqual(presentation.status, .updateAvailable)
        XCTAssertEqual(presentation.check?.sources.last?.outcome, .failed)
        XCTAssertNil(presentation.check?.lastSuccessfulCheck)
    }
}
