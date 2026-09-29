import SwiftUI
import MacUpdaterCore

@MainActor
final class CaskReleaseNotesLoader: ObservableObject {
    enum State: Equatable {
        case idle, loading, unavailable, failed
        case loaded(ReleaseNotes)
    }
    @Published private(set) var state: State = .idle
    private let fetch: (CaskReleaseNotesRequest) async -> CaskReleaseNotesProvider.Outcome

    init(fetch: @escaping (CaskReleaseNotesRequest) async -> CaskReleaseNotesProvider.Outcome = {
        await CaskReleaseNotesProvider().notes(for: $0)
    }) {
        self.fetch = fetch
    }

    func loadIfNeeded(_ request: CaskReleaseNotesRequest) async {
        guard state == .idle else { return }
        await load(request)
    }

    func retry(_ request: CaskReleaseNotesRequest) async {
        guard state == .failed else { return }
        await load(request)
    }

    private func load(_ request: CaskReleaseNotesRequest) async {
        state = .loading
        let result = await fetch(request)
        guard !Task.isCancelled else { state = .idle; return }
        switch result {
        case .notes(let notes): state = .loaded(notes)
        case .unavailable: state = .unavailable
        case .failed: state = .failed
        }
    }
}

struct CaskReleaseNotesView: View {
    let request: CaskReleaseNotesRequest
    @StateObject private var loader = CaskReleaseNotesLoader()
    @State private var requestNumber = 0

    var body: some View {
        Group {
            switch loader.state {
            case .idle:
                Button(tr("Sprawdź notatki wydania")) { requestNumber += 1 }
                    .buttonStyle(.plain)
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("Pobieram notatki wydania…"))
                }
            case .loaded(let notes):
                ReleaseNotesDisclosure(notes: notes, expanded: true)
            case .unavailable:
                Text(tr("Brak jednoznacznych notatek dla tej wersji"))
            case .failed:
                HStack {
                    Text(tr("Nie udało się pobrać notatek wydania"))
                    Button(tr("Spróbuj ponownie")) { requestNumber += 1 }
                        .controlSize(.small)
                }
            }
        }
        .font(.wega(.subheadline))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: requestNumber) {
            guard requestNumber > 0 else { return }
            if loader.state == .failed { await loader.retry(request) }
            else { await loader.loadIfNeeded(request) }
        }
    }
}
