import AppKit
import SwiftUI
import MacUpdaterCore

enum CleanupPage: CaseIterable {
    case tools, installers, xcode

    var title: String {
        switch self {
        case .tools: tr("Narzędzia")
        case .installers: tr("Stare instalatory")
        case .xcode: tr("Porządki po Xcode")
        }
    }
}

struct CleanupFileReviewView: View {
    let page: CleanupPage
    let search: String
    @ObservedObject var store: CleanupFileReviewStore
    @State private var showsRuntimes = false
    @State private var order = CleanupFileOrder.largest
    @State private var confirming: ReviewedCleanupFile?

    var body: some View {
        Group {
            if page == .xcode {
                xcodeReview
            } else {
                CleanupInstallerReviewView(store: store) { confirming = $0 }
            }
        }
        .alert(item: $confirming) { file in
            let details = file.id.path + "\n\n" + (page == .installers
                ? tr("Do Kosza trafi wybrany instalator.")
                : tr("Do Kosza trafi katalog danych kompilacji wraz z logami i wynikami testów. Xcode ponownie zbuduje projekt przy kolejnym użyciu."))
            return Alert(title: Text(trf("Przenieść „%@” do Kosza?", file.name)), message: Text(details),
                         primaryButton: .cancel(Text(tr("Anuluj"))),
                         secondaryButton: .destructive(Text(tr("Przenieś do Kosza"))) { store.moveToTrash(file) })
        }
        .sheet(isPresented: $showsRuntimes) { SimulatorRuntimeReviewView(store: store) }
        .wegaAttention(confirming != nil || store.error != nil || showsRuntimes)
    }

    private var xcodeReview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { store.scan(.xcode) } label: { Label(tr("Skanuj"), systemImage: "magnifyingglass") }
                Button { showsRuntimes = true } label: {
                    Label(tr("Środowiska symulatorów"), systemImage: "iphone")
                }
                Spacer()
                CleanupFileSortPicker(order: $order)
            }
            .disabled(store.phase != .idle)
            CleanupFileReviewStatus(store: store)
            if let files = store.files {
                results(files)
            } else if !store.scanCancelled && store.phase == .idle && store.error == nil {
                Text(tr("Skan pokaże dane kompilacji projektów i archiwa wydań ze standardowych folderów Xcode."))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func results(_ files: [ReviewedCleanupFile]) -> some View {
        let visible = order.visibleFiles(files, search: search)
        if visible.isEmpty {
            let searching = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Text(searching ? tr("Brak pasujących pozycji.") : tr("Nie znaleziono danych projektów ani archiwów Xcode."))
                .foregroundStyle(.secondary)
        } else {
            List {
                let projects = visible.filter { if case .xcode(let item) = $0 { item.kind == .derivedData } else { false } }
                let archives = visible.filter { if case .xcode(let item) = $0 { item.kind == .archive } else { false } }
                if !projects.isEmpty {
                    Section(tr("Dane kompilacji projektów (DerivedData)")) { ForEach(projects) { row($0) } }
                }
                if !archives.isEmpty {
                    Section(tr("Archiwa wydań (.xcarchive)")) { ForEach(archives) { row($0) } }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ file: ReviewedCleanupFile) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: file.name).font(.wega(.body, weight: .semibold)).lineLimit(2)
                HStack {
                    Text(file.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? tr("rozmiar nieznany"))
                    Text(file.modified, format: .dateTime.year().month().day().hour().minute())
                }
                .font(.wega(.footnote)).foregroundStyle(.secondary)
                if case let .xcode(item) = file {
                    Text(verbatim: file.id.path).lineLimit(1).truncationMode(.middle)
                        .font(.wega(.footnote)).foregroundStyle(.secondary)
                    if item.kind == .derivedData && !file.canTrash {
                        Text(tr("Tylko podgląd: dane są świeże lub nie udało się potwierdzić, że można je usunąć."))
                            .font(.wega(.footnote)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.id]) } label: {
                Image(systemName: "folder")
            }
            .help(tr("Pokaż w Finderze")).accessibilityLabel(trf("Pokaż w Finderze: %@", file.name))
            if file.canTrash {
                Button { confirming = file } label: { Image(systemName: "trash") }
                    .help(tr("Przenieś do Kosza")).accessibilityLabel(trf("Przenieś do Kosza: %@", file.name))
            }
        }
        .buttonStyle(.borderless)
        .disabled(store.phase != .idle)
        .padding(.vertical, 4)
    }
}

struct CleanupFileSortPicker: View {
    @Binding var order: CleanupFileOrder

    var body: some View {
        Picker(tr("Sortowanie"), selection: $order) {
            Text(tr("Największe najpierw")).tag(CleanupFileOrder.largest)
            Text(tr("Najstarsze najpierw")).tag(CleanupFileOrder.oldest)
        }
        .labelsHidden()
        .fixedSize()
    }
}

struct CleanupFileReviewStatus: View {
    @ObservedObject var store: CleanupFileReviewStore

    @ViewBuilder var body: some View {
        if let error = store.error { ErrorBanner(message: error) }
        if let name = store.movedName {
            Label(trf("Przeniesiono do Kosza: %@", name), systemImage: "checkmark.circle")
                .font(.wega(.subheadline))
        }
        if store.phase != .idle {
            HStack {
                ProgressView().controlSize(.small)
                Text(store.phase == .scanning ? tr("Skanuję…") : tr("Usuwam…"))
                if store.phase == .scanning {
                    Button(tr("Anuluj")) { store.cancelScan() }
                }
            }
        }
        if store.scanCancelled {
            Text(tr("Skan anulowany. Możesz ponowić skan.")).foregroundStyle(.secondary)
        }
    }
}
