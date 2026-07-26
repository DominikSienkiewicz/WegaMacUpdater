import AppKit
import MacUpdaterCore
import SwiftUI

/// UX-16 — the Settings surface for configurable scan directories, exclusions and recursion
/// depth. It edits `UserDefaults` through `ScanConfigurationStore`; the scan seams
/// (`buildScanDirs`, `ManualUpdateScanner`) read the same keys, so a change here takes effect
/// on the next scan without any wiring between the two.
@MainActor
final class ScanDirectoriesSettingsModel: ObservableObject {
    @Published private(set) var userDirectories: [URL] = []
    @Published private(set) var exclusions: [URL] = []
    @Published private(set) var recursionDepth: Int = ScanConfiguration.defaultRecursionDepth

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    func reload() {
        userDirectories = ScanConfigurationStore.resolvedUserDirectories(from: defaults)
        exclusions = ScanConfigurationStore.exclusionPaths(from: defaults)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        recursionDepth = ScanConfigurationStore.recursionDepth(from: defaults)
    }

    func addUserDirectory(_ url: URL) {
        ScanConfigurationStore.addUserDirectory(url, to: defaults)
        reload()
    }

    func removeUserDirectory(_ url: URL) {
        ScanConfigurationStore.removeUserDirectory(
            resolvedPath: url.resolvingSymlinksInPath().path, from: defaults
        )
        reload()
    }

    func addExclusion(_ url: URL) {
        ScanConfigurationStore.addExclusion(url, to: defaults)
        reload()
    }

    func removeExclusion(_ url: URL) {
        ScanConfigurationStore.removeExclusion(path: url.standardizedFileURL.path, from: defaults)
        reload()
    }

    func setRecursionDepth(_ depth: Int) {
        ScanConfigurationStore.setRecursionDepth(depth, in: defaults)
        recursionDepth = ScanConfigurationStore.recursionDepth(from: defaults)
    }
}

struct ScanDirectoriesSettingsCard: View {
    @StateObject private var model = ScanDirectoriesSettingsModel()

    private var depthBinding: Binding<Int> {
        Binding(get: { model.recursionDepth }, set: { model.setRecursionDepth($0) })
    }

    var body: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                Label(tr("Katalogi skanowania"), systemImage: "folder.badge.gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.wegaHoney)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("Wega skanuje /Applications, ~/Applications i ich podfoldery. Dodaj własne katalogi (także na innych wolumenach), pomiń te, których nie chcesz przeszukiwać, i ustaw głębokość zagłębiania."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    depthRow
                    Divider().opacity(0.4)
                    directoriesSection
                    Divider().opacity(0.4)
                    exclusionsSection
                }
                .padding(14)
            }
        }
    }

    // MARK: - Recursion depth

    private var depthRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Głębokość zagłębiania")).font(.system(size: 12))
                Text(tr("0 = tylko sam katalog. 1 = katalog i jego bezpośrednie podfoldery."))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(model.recursionDepth)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Stepper("", value: depthBinding, in: 0...ScanConfiguration.maximumRecursionDepth)
                .labelsHidden()
        }
    }

    // MARK: - User directories

    private var directoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Katalogi użytkownika")).font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    if let url = chooseDirectory(prompt: tr("Dodaj do skanowania")) {
                        model.addUserDirectory(url)
                    }
                } label: { Label(tr("Dodaj katalog…"), systemImage: "plus") }
                    .controlSize(.small)
            }

            if model.userDirectories.isEmpty {
                Text(tr("Brak własnych katalogów."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.userDirectories, id: \.self) { url in
                    pathRow(url, icon: "folder", remove: { model.removeUserDirectory(url) })
                }
            }
        }
    }

    // MARK: - Exclusions

    private var exclusionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Wykluczenia")).font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    if let url = chooseDirectory(prompt: tr("Wyklucz ze skanowania")) {
                        model.addExclusion(url)
                    }
                } label: { Label(tr("Dodaj wykluczenie…"), systemImage: "plus") }
                    .controlSize(.small)
            }

            if model.exclusions.isEmpty {
                Text(tr("Brak wykluczeń."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.exclusions, id: \.self) { url in
                    pathRow(url, icon: "nosign", remove: { model.removeExclusion(url) })
                }
            }
        }
    }

    // MARK: - Row + picker

    private func pathRow(_ url: URL, icon: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(action: remove) {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(tr("Usuń"))
        }
    }

    private func chooseDirectory(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
}
