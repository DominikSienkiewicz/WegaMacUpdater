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

    /// Lock-guarded so it is safe to touch from inside a `@Sendable` gatherer closure —
    /// the counter itself is not actor-isolated, only its access is serialized.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        @discardableResult
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
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
        // The address is emitted literally: `@` is the mailto separator, and encoding a
        // reserved delimiter changes what the URI means. An overlay-supplied address is
        // validated in `AppEndpoints.overlaying(_:)`, so the injection shape never gets here.
        #expect(opener.opened.first?.absoluteString.hasPrefix(
            "mailto:" + AppEndpoints.shared.supportEmailAddress + "?subject="
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

    /// `@MainActor` isolation is reentrant across suspension points: without an in-flight
    /// handle, two overlapping `loadEnvironment()` calls each see `environment == nil` and
    /// each kick off a full gather. `snapshot()` shells out to brew, mas, npm and the
    /// privileged helper — a real double gather costs seconds, not milliseconds — so this
    /// asserts the gather itself runs exactly once no matter how many callers overlap.
    @Test func loadEnvironmentGathersOnlyOnceUnderOverlappingCalls() async {
        let counter = Counter()
        let controller = BugReportController(entries: [entry("foo padł")], opener: SpyOpener()) {
            counter.increment()
            try? await Task.sleep(for: .milliseconds(20))
            return [ReportField(label: "Wega", value: "1.4.2 (812)")]
        }

        async let first: Void = controller.loadEnvironment()
        async let second: Void = controller.loadEnvironment()
        _ = await (first, second)

        #expect(counter.current == 1)
        #expect(controller.environment != nil)
    }

    /// `WegaLog` hands its entry to the store from a detached task, so the success line
    /// cannot be observed synchronously here — what this pins is that the line names the
    /// channel at all. "A report was created" without saying where it went leaves a later
    /// reader with the one question they actually have.
    @Test func theSuccessLogNamesTheChannelThatWasOpened() throws {
        let source = try Self.source("Sources/MacUpdater/BugReportController.swift")
        let successLine = try #require(
            source.split(separator: "\n").first { $0.contains("Utworzono zgłoszenie błędu") }
        )
        #expect(successLine.contains("channelLabel(channel)"))
    }

    /// `.sheet(item:)` reopens whenever the identity changes, so identity has to belong to
    /// the controller and not to the memory it happens to occupy: `ObjectIdentifier(self)`
    /// is the allocation address, which the allocator may hand to the next controller once
    /// this one is gone. Pinned by reading the source, because reproducing an address reuse
    /// on demand is not something a test can do reliably.
    @Test func theIdentityIsAValueOfItsOwnRatherThanTheAllocationAddress() throws {
        let source = try Self.source("Sources/MacUpdater/BugReportController.swift")
        #expect(source.contains("var id: ObjectIdentifier") == false)
        #expect(source.contains("nonisolated let id = UUID()"))

        let first = BugReportController(entries: [entry("foo padł")], opener: SpyOpener())
        let second = BugReportController(entries: [entry("foo padł")], opener: SpyOpener())
        #expect(first.id != second.id)
    }

    private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
