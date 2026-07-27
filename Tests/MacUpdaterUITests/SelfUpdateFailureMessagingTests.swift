import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// UX-11b (D10) — a failed self-update download falls back to opening the release page in the
/// browser so the user can still grab the update by hand. That fallback must be explained: the
/// user is told the download failed and that the browser is opening, *before* it opens.
///
/// The refactor that first extracted `SelfUpdateController` opened the browser with no message
/// at all — the browser appeared "without explanation". This suite pins the explanation so the
/// fallback can never silently regress to that state.
@Suite("Self-update failure messaging")
@MainActor
struct SelfUpdateFailureMessagingTests {
    @Test func aFailedDownloadExplainsTheBrowserFallbackBeforeOpeningIt() async {
        let log = SelfUpdateFailureLog()
        let controller = SelfUpdateController(
            dependencies: .init(
                check: { .upToDate },
                download: { _ in throw URLError(.notConnectedToInternet) },
                verify: { _, _ in },
                installOrOpen: { _, _ in false },
                openFallback: { log.record(.openedBrowser) },
                relaunch: {},
                isBusy: { false },
                fetchHistory: { _ in .unavailable }
            )
        )

        let asset = ReleaseAsset(name: "Wega.dmg", url: URL(fileURLWithPath: "/tmp/Wega.dmg"))
        await controller.apply(.downloadAndOpen(asset: asset), version: "1.0.1") { state in
            log.record(.message(state.line))
        }

        let explanation = SelfUpdatePresentation.message(for: .failed)
        let explainedAt = log.events.firstIndex(of: .message(explanation))
        let openedBrowserAt = log.events.firstIndex(of: .openedBrowser)

        #expect(
            openedBrowserAt != nil,
            "a failed download must still fall back to opening the release page"
        )
        #expect(
            explainedAt != nil,
            "the user must be told why the browser is opening, not left without explanation"
        )
        if let explainedAt, let openedBrowserAt {
            #expect(
                explainedAt < openedBrowserAt,
                "the explanation must precede the browser, not arrive after it has opened"
            )
        }
    }
}

/// Records, in order, the user-facing messages the controller emits and the moment it opens the
/// browser fallback — so a test can assert the explanation lands before the browser.
@MainActor
private final class SelfUpdateFailureLog {
    enum Event: Equatable {
        case message(String)
        case openedBrowser
    }

    private(set) var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }
}
