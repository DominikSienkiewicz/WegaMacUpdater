import AppKit
import MacUpdaterCore
import SwiftUI

/// Observable state for the folders Cleanup reads project version files from. It edits
/// `UserDefaults` through `CleanupProjectRoots`; a refused folder is reported in `rejection`.
@MainActor
final class CleanupProjectRootsSettingsModel: ObservableObject {
    @Published private(set) var roots: [URL] = []
    @Published private(set) var rejection: CleanupProjectRootRejection?

    private let defaults: UserDefaults
    private let home: URL
    private let protectedLocations: ProtectedLocationGuard

    init(
        defaults: UserDefaults = .standard,
        home: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
        protectedLocations: ProtectedLocationGuard? = nil
    ) {
        self.defaults = defaults
        self.home = home
        self.protectedLocations = protectedLocations ?? ProtectedLocationGuard(home: home, mounts: LiveMountTable())
        reload()
    }

    func add(_ url: URL) {
        rejection = CleanupProjectRoots.add(url, to: defaults, home: home, protectedLocations: protectedLocations)
        reload()
    }

    func remove(_ url: URL) {
        CleanupProjectRoots.remove(url, from: defaults, home: home)
        rejection = nil
        reload()
    }

    private func reload() {
        roots = CleanupProjectRoots.roots(from: defaults, home: home)
    }
}

struct CleanupProjectRootsSettingsCard: View {
    @StateObject private var model = CleanupProjectRootsSettingsModel()

    var body: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "folder.badge.questionmark", title: tr("Katalogi projektów"), titleTinted: true)

                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("Porządki czytają tu pliki wersji (.python-version, .nvmrc, wrapper Gradle…), żeby nie proponować usunięcia tego, czego używają projekty. Lokalizacje chronione (Dokumenty, Biurko, Pobrane, iCloud) są odrzucane."))
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Spacer()
                        Button {
                            if let url = chooseDirectory() { model.add(url) }
                        } label: { Label(tr("Dodaj katalog…"), systemImage: "plus") }
                            .controlSize(.small)
                    }

                    if let rejection = model.rejection {
                        Text(message(for: rejection))
                            .font(.wega(.subheadline))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(model.roots, id: \.self) { url in
                        row(url)
                    }
                }
                .padding(14)
            }
        }
    }

    private func message(for rejection: CleanupProjectRootRejection) -> String {
        switch rejection {
        case .protectedLocation: tr("Ten katalog leży w lokalizacji chronionej, więc Wega go nie przeszuka.")
        case .alreadyListed: tr("Ten katalog jest już na liście.")
        }
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 16)
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .font(.wega(.subheadline, monospaced: true))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button { model.remove(url) } label: {
                Image(systemName: "trash").font(.wega(.subheadline))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(tr("Usuń"))
        }
    }

    private func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = tr("Dodaj katalog…")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
