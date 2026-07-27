import Testing
import Foundation
@testable import MacUpdaterCore
@testable import WegaMacUpdater

/// The notes are informative, never a gate: a history that cannot be fetched leaves the update
/// itself perfectly installable.
@MainActor
@Suite("SelfUpdate history")
struct SelfUpdateHistoryTests {
    private func controller(
        check: WegaSelfUpdateChecker.Result,
        history: ReleaseHistoryFetcher.Outcome
    ) -> SelfUpdateController {
        SelfUpdateController(dependencies: SelfUpdateController.Dependencies(
            check: { check },
            download: { $0 },
            verify: { _ in },
            installOrOpen: { _, _ in true },
            openFallback: {},
            relaunch: {},
            isBusy: { false },
            fetchHistory: { _ in history }
        ))
    }

    private var available: WegaSelfUpdateChecker.Result {
        .updateAvailable(
            version: "1.2.0",
            assets: [ReleaseAsset(name: "Wega.pkg", url: URL(string: "https://example.com/Wega.pkg")!)],
            releaseURL: URL(string: "https://example.com/release")!,
            notes: ""
        )
    }

    @Test func loadsTheHistoryAlongsideAnAvailableUpdate() async {
        let notes = ReleaseHistory(
            notes: [ReleaseNote(version: "1.2.0", publishedAt: nil, body: "Fixed a crash")],
            omitted: 0
        )
        let controller = self.controller(check: available, history: .history(notes))

        await controller.check()

        #expect(controller.history == .history(notes))
    }

    @Test func anUnavailableHistoryStillLeavesTheUpdateActionable() async {
        let controller = self.controller(check: available, history: .unavailable)

        await controller.check()

        #expect(controller.history == .unavailable)
        #expect(controller.result == available)
    }

    /// Nothing to update means nothing to explain — no history request is made.
    @Test func skipsTheHistoryWhenAlreadyUpToDate() async {
        let controller = self.controller(check: .upToDate, history: .unavailable)

        await controller.check()

        #expect(controller.history == nil)
    }
}
