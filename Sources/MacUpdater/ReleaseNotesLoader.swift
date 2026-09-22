import Foundation
import MacUpdaterCore

/// The state behind a row's "Co nowego" when the feed published a link instead of a body.
///
/// Lives outside the view so the rule — load once, on first expansion, never during a scan —
/// is testable without SwiftUI. A row nobody expands makes no request at all, which is the
/// whole reason the fetch is here and not in `ManualUpdateScanner`.
@MainActor
final class ReleaseNotesLoader: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(text: String, truncated: Bool)
        case failed
    }

    @Published private(set) var state: State = .idle

    // Not `@Sendable`: the class is already `@MainActor`, so the closure is main-actor
    // isolated and needs no extra guarantee. Marking it `@Sendable` would also forbid the
    // tests from counting calls in a captured local.
    private let fetch: (URL) async -> ReleaseNotesLinkFetcher.Outcome

    init(fetch: @escaping (URL) async -> ReleaseNotesLinkFetcher.Outcome) {
        self.fetch = fetch
    }

    convenience init(fetcher: ReleaseNotesLinkFetcher = ReleaseNotesLinkFetcher()) {
        self.init { await fetcher.text(at: $0) }
    }

    /// Loads exactly once. A second expansion of the same row re-reads what is already here.
    func loadIfNeeded(from link: URL?) async {
        guard case .idle = state else { return }
        await load(from: link)
    }

    /// The user asking again after a failure — the one way back out of `.failed`.
    func retry(from link: URL?) async {
        guard case .failed = state else { return }
        await load(from: link)
    }

    private func load(from link: URL?) async {
        guard let link else { return }
        state = .loading
        switch await fetch(link) {
        case .notes(let text, let truncated):
            state = .loaded(text: text, truncated: truncated)
        case .unavailable:
            state = .failed
        }
    }
}
