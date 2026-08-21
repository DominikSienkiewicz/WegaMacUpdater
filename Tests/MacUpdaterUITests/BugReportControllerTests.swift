import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// Zachowanie okna zgłoszenia bez dotykania prawdziwego `NSWorkspace` — inaczej
/// „brak klienta poczty" dałoby się sprawdzić tylko odinstalowując klienta poczty
/// z maszyny, na której lecą testy.
@Suite("BugReportController")
@MainActor
struct BugReportControllerTests {

    private final class SpyOpener: URLOpening, @unchecked Sendable {
        var handles = true
        private(set) var opened: [URL] = []
        func canOpen(_ url: URL) -> Bool { handles }
        func open(_ url: URL) -> Bool {
            guard handles else { return false }
            opened.append(url)
            return true
        }
    }

    private func entry(_ message: String) -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: 1_770_000_000), level: .error,
                 category: .homebrew, message: message)
    }

    private func ready(_ opener: SpyOpener) -> BugReportController {
        let controller = BugReportController(entries: [entry("foo padł")], opener: opener)
        controller.applyEnvironmentForTests([ReportField(label: "Wega", value: "1.4.2 (812)")])
        return controller
    }

    @Test func sendingOpensTheChannelURL() {
        let opener = SpyOpener()
        let controller = ready(opener)
        controller.send(controller.emailChannel)
        #expect(opener.opened.count == 1)
        #expect(opener.opened.first?.scheme == "mailto")
        #expect(controller.outcome == .opened(controller.emailChannel))
    }

    @Test func aMissingMailClientYieldsNoHandlerRatherThanAnError() {
        let opener = SpyOpener()
        opener.handles = false
        let controller = ready(opener)
        controller.send(controller.emailChannel)
        #expect(opener.opened.isEmpty)
        #expect(controller.outcome == .noHandler(controller.emailChannel))
    }

    @Test func theGitHubChannelTargetsTheConfiguredNewIssueEndpoint() {
        let opener = SpyOpener()
        let controller = ready(opener)
        controller.send(controller.gitHubChannel)
        #expect(opener.opened.first?.absoluteString.hasPrefix(
            AppEndpoints.shared.projectNewIssueURL.absoluteString + "?title=") == true)
    }

    @Test func theEmailChannelUsesTheConfiguredSupportAddress() {
        let opener = SpyOpener()
        let controller = ready(opener)
        controller.send(controller.emailChannel)
        // The address is percent-encoded to prevent mailto header injection from an
        // overlay-supplied address — do not "simplify" this back to the raw address.
        #expect(opener.opened.first?.absoluteString.hasPrefix(
            "mailto:" + PrefilledURLBody.percentEncoded(AppEndpoints.shared.supportEmailAddress)
        ) == true)
    }

    @Test func thePreviewIsExactlyWhatTheURLCarries() {
        let controller = ready(SpyOpener())
        controller.userDescription = "Kliknąłem aktualizuj."
        let preview = controller.preview(for: controller.emailChannel)
        #expect(preview.text.contains("Kliknąłem aktualizuj."))
        #expect(preview.text.contains("- Wega: 1.4.2 (812)"))
        #expect(preview.text.contains("foo padł"))
    }

    @Test func sendingIsBlockedUntilTheEnvironmentIsGathered() {
        let pending = BugReportController(entries: [entry("foo padł")], opener: SpyOpener())
        #expect(pending.isReady == false)
        pending.applyEnvironmentForTests([])
        #expect(pending.isReady)
    }
}
