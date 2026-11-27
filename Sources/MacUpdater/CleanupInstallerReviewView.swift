import AppKit
import SwiftUI
import MacUpdaterCore
import UniformTypeIdentifiers

struct CleanupInstallerReviewView: View {
    @ObservedObject var store: CleanupFileReviewStore
    let onTrash: (ReviewedCleanupFile) -> Void

    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var order = CleanupFileOrder.largest
    @State private var expandedFile: URL?

    var body: some View {
        if let folder = store.installerFolder {
            VStack(alignment: .leading, spacing: 12) {
                folderHeader(folder)
                Divider()
                filters(in: folder)
                CleanupFileReviewStatus(store: store)
                if let files = store.files { results(files) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .searchable(text: $search, prompt: tr("Szukaj instalatora…"))
            .searchFocused($searchFocused)
            .receivesSearchFocusRequests(on: .cleanup) { searchFocused = true }
            .onChange(of: store.phase) { _, phase in
                if phase == .scanning { expandedFile = nil }
            }
        } else {
            EmptyHero(title: tr("Przejrzyj stare instalatory"),
                      message: tr("Wybierz folder, np. Pobrane. Wega pokaże instalatory, których nie zmieniano od co najmniej 30 dni."),
                      action: AnyView(
                        Button(action: chooseFolder) { Label(tr("Wybierz folder…"), systemImage: "folder") }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .tint(Color.wegaHoneyFill).foregroundStyle(Color.wegaInk)
                      ), compact: true)
        }
    }

    private func folderHeader(_ folder: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").font(.wega(.title)).foregroundStyle(Color.wegaHoney)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                InstallerFolderName(folder: folder)
                    .id(folder)
                    .font(.wega(.title2, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .help(folder.path)
                if let files = store.files {
                    Text(InstallerReviewSummary.text(sizes: files.compactMap(\.bytes)))
                        .font(.wega(.subheadline)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button(tr("Zmień folder…"), action: chooseFolder)
            Button { scan(folder) } label: {
                Label(tr("Sprawdź ponownie"), systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            }
            .help(tr("Sprawdź ponownie"))
        }
        .disabled(store.phase != .idle)
    }

    private func filters(in folder: URL) -> some View {
        HStack(spacing: 12) {
            Picker(tr("Wiek instalatorów"), selection: $store.allInstallerAges) {
                Text(tr("Co najmniej 30 dni")).tag(false)
                Text(tr("Wszystkie")).tag(true)
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: store.allInstallerAges) { _, _ in scan(folder) }
            if let files = store.files, files.count > 1 {
                CleanupFileSortPicker(order: $order)
            }
        }
        .disabled(store.phase != .idle)
    }

    @ViewBuilder
    private func results(_ files: [ReviewedCleanupFile]) -> some View {
        let visible = order.visibleFiles(files, search: search)
        if visible.isEmpty {
            Text(files.isEmpty ? tr("Brak instalatorów dla wybranego wieku.") : tr("Brak pasujących pozycji."))
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { file in
                        if case let .installer(item, _) = file {
                            if file.id != visible.first?.id { Divider() }
                            CleanupInstallerRow(url: file.id, size: item.size, modified: item.modifiedAt,
                                                installedVersion: item.installedVersion,
                                                expanded: Binding(get: { expandedFile == file.id },
                                                                  set: { expandedFile = $0 ? file.id : nil }),
                                                onReveal: { NSWorkspace.shared.activateFileViewerSelecting([file.id]) },
                                                onTrash: { onTrash(file) })
                        }
                    }
                }
                .padding(.horizontal, WegaLayout.cardPadding)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WegaLayout.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: WegaLayout.cardRadius).strokeBorder(.quaternary)
                        .allowsHitTesting(false)
                }
            }
            .disabled(store.phase != .idle)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.prompt = tr("Wybierz folder")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        if folder != store.installerFolder { search = "" }
        scan(folder)
    }

    private func scan(_ folder: URL) {
        store.scan(.installers(folder, store.allInstallerAges ? .all : .olderThan30Days))
    }
}

private struct InstallerFolderName: View {
    let folder: URL
    @State private var localizedName: String?

    var body: some View {
        Text(verbatim: localizedName ?? folder.lastPathComponent)
            .task {
                localizedName = await Task.detached(priority: .utility) { [folder] in
                    try? folder.resourceValues(forKeys: [.localizedNameKey]).localizedName
                }.value
            }
    }
}

enum InstallerReviewSummary {
    static func text(sizes: [Int64]) -> String {
        let count = trp("%@ instalatorów", sizes.count)
        var total: Int64 = 0
        for size in sizes {
            let addition = total.addingReportingOverflow(size)
            guard !addition.overflow else { return count }
            total = addition.partialValue
        }
        return count + " · " + sizeText(total)
    }

    static func sizeText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false).locale(Locale(identifier: LocalizedStrings.current.rawValue)))
    }
}

struct CleanupInstallerRow: View {
    let url: URL
    let size: Int64
    let modified: Date
    let installedVersion: String?
    @Binding var expanded: Bool
    let onReveal: () -> Void
    let onTrash: () -> Void

    private static let diskImage = NSWorkspace.shared.icon(for: UTType(filenameExtension: "dmg") ?? .diskImage)
    private static let package = NSWorkspace.shared.icon(for: UTType(filenameExtension: "pkg") ?? .package)

    var body: some View {
        WegaDisclosure(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                if let installedVersion { Text(trf("Zainstalowana wersja: %@", installedVersion)) }
                Text(trf("Do Kosza trafi tylko plik %@.", url.lastPathComponent))
                Text(tr("Możesz go przywrócić do czasu opróżnienia Kosza."))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actions }.fixedSize()
                    VStack(alignment: .leading, spacing: 6) { actions }
                }
                .padding(.top, 6)
            }
            .font(.wega(.callout))
            .padding(.leading, 60)
            .padding(.bottom, 12)
        } label: {
            HStack(spacing: 12) {
                Image(nsImage: url.pathExtension.lowercased() == "pkg" ? Self.package : Self.diskImage)
                    .resizable().scaledToFit().frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: url.lastPathComponent).font(.wega(.headline)).lineLimit(2).truncationMode(.middle)
                    Text(trf("Zmieniono %@", modified.formatted(.dateTime.day().month(.abbreviated).year()
                        .locale(Locale(identifier: LocalizedStrings.current.rawValue)))))
                        .font(.wega(.subheadline)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(InstallerReviewSummary.sizeText(size)).font(.wega(.body)).monospacedDigit().fixedSize()
            }
            .padding(.vertical, 12)
            .layoutPriority(1)
        }
    }

    @ViewBuilder private var actions: some View {
        Button(action: onReveal) { Label(tr("Pokaż w Finderze"), systemImage: "folder") }
            .accessibilityLabel(trf("Pokaż w Finderze: %@", url.lastPathComponent))
        Button(action: onTrash) { Label(tr("Przenieś do Kosza…"), systemImage: "trash") }
            .accessibilityLabel(trf("Przenieś do Kosza: %@", url.lastPathComponent))
    }
}
