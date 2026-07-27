import Foundation
import XCTest
import MacUpdaterCore

@testable import WegaMacUpdater

/// UX-06 — the self-update button and its outcome messages describe the operation that will
/// actually run: a headless `install` versus a `download`-and-`open` handoff, and a distinct
/// `error` when neither happens.
final class SelfUpdatePresentationTests: XCTestCase {
    // Task 2 gave `SelfUpdateAction` cases an associated `ReleaseAsset`; the asset's contents are
    // irrelevant to these label-copy assertions, so one placeholder covers both cases.
    private let asset = ReleaseAsset(name: "Wega.pkg", url: URL(string: "https://example.com/Wega.pkg")!)

    func testInstallActionIsLabelledAsInstall() {
        let label = SelfUpdatePresentation.actionLabel(.install(pkg: asset))
        XCTAssertTrue(label.contains(tr("Pobierz i zainstaluj")), label)
    }

    /// The bug the card names: "Pobierz i zainstaluj" over an operation that only downloads
    /// and opens an installer. The download-and-open label must not promise an install.
    func testDownloadAndOpenActionDoesNotClaimToInstall() {
        let label = SelfUpdatePresentation.actionLabel(.downloadAndOpen(asset: asset))
        XCTAssertNotEqual(label, SelfUpdatePresentation.actionLabel(.install(pkg: asset)))
        XCTAssertFalse(label.contains("zainstaluj"),
                       "a download-and-open handoff must not be labelled as an install: \(label)")
    }

    /// Every operation state has its own message, so `download`/`open`/`install`/`error`
    /// never share one line of copy.
    func testEveryOperationStateHasADistinctMessage() {
        let messages = Set([
            SelfUpdatePresentation.message(for: .downloading),
            SelfUpdatePresentation.message(for: .opened),
            SelfUpdatePresentation.message(for: .installed),
            SelfUpdatePresentation.message(for: .failed)
        ])
        XCTAssertEqual(messages.count, 4, "download/open/install/error must not share copy")
    }
}
