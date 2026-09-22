import Testing
import Foundation
@testable import WegaMacUpdater
@testable import MacUpdaterCore

@MainActor
@Suite("ReleaseNotesLoader")
struct ReleaseNotesLoaderTests {

    private let link = URL(string: "https://example.com/notes")!

    @Test func startsIdleAndLoadsOnce() async {
        var calls = 0
        let loader = ReleaseNotesLoader { _ in
            calls += 1
            return .notes(text: "Fixed a crash", truncated: false)
        }

        #expect(loader.state == .idle)

        await loader.loadIfNeeded(from: link)
        await loader.loadIfNeeded(from: link)

        #expect(calls == 1)
        #expect(loader.state == .loaded(text: "Fixed a crash", truncated: false))
    }

    @Test func noLinkIsNotAFailedLoad() async {
        let loader = ReleaseNotesLoader { _ in .notes(text: "unused", truncated: false) }

        await loader.loadIfNeeded(from: nil)

        #expect(loader.state == .idle)
    }

    @Test func anUnavailablePageIsReportedAsFailed() async {
        let loader = ReleaseNotesLoader { _ in .unavailable }

        await loader.loadIfNeeded(from: link)

        #expect(loader.state == .failed)
    }

    @Test func aFailedLoadCanBeRetried() async {
        var outcomes: [ReleaseNotesLinkFetcher.Outcome] = [
            .unavailable,
            .notes(text: "Second time lucky", truncated: false),
        ]
        let loader = ReleaseNotesLoader { _ in outcomes.removeFirst() }

        await loader.loadIfNeeded(from: link)
        #expect(loader.state == .failed)

        await loader.retry(from: link)
        #expect(loader.state == .loaded(text: "Second time lucky", truncated: false))
    }

    @Test func aCancelledLoadDoesNotMasqueradeAsAFailure() async {
        let loader = ReleaseNotesLoader { _ in .unavailable }

        let task = Task { await loader.loadIfNeeded(from: link) }
        task.cancel()
        await task.value

        #expect(loader.state == .idle)
    }
}
