import SwiftUI
import MacUpdaterCore

struct UninstallView: View {
    var onWegaState: ((WegaState) -> Void)?

    @EnvironmentObject private var model: AppViewModel

    @State private var apps:          [ApplicationInfo] = []
    @State private var selected:       Set<String>       = []
    @State private var search:         String            = ""
    @State private var isLoading:      Bool              = false
    @State private var isUninstalling: Bool              = false
    @State private var showDialog:     Bool              = false
    @State private var errorMessage:   String?
    @State private var banner:         BannerData?
    @FocusState private var searchFocused: Bool

    private var filtered: [ApplicationInfo] {
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var selectedBrewCount: Int { filtered.filter { selected.contains($0.id) && $0.isManagedByBrew }.count }
    private var selectedTrashCount: Int { filtered.filter { selected.contains($0.id) && !$0.isManagedByBrew }.count }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("Odinstaluj aplikacje")).font(.system(size: 18, weight: .semibold))
                        Text(tr("Brew casks → brew uninstall  ·  pozostałe → Kosz"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 13))
                        TextField(tr("Szukaj…"), text: $search)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .frame(width: 180)
                            .focused($searchFocused)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .onTapGesture { searchFocused = true }

                    Button { Task { await scan() } } label: {
                        Label(tr("Reload"), systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)

                    Button {
                        guard !selected.isEmpty else { return }
                        showDialog = true
                    } label: {
                        if isUninstalling { ProgressView().controlSize(.small) }
                        else { Label(selected.isEmpty ? tr("Odinstaluj") : trf("Odinstaluj (%@)", "\(selected.count)"), systemImage: "trash") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wegaDanger)
                    .disabled(selected.isEmpty || isUninstalling)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let err = errorMessage {
                    ErrorBanner(message: err).padding(.horizontal, 16).padding(.bottom, 8)
                }
                if let b = banner {
                    BannerView(data: b) { banner = nil }.padding(.horizontal, 16).padding(.bottom, 8)
                }

                // Select-all row
                WegaCard(padded: false) {
                    HStack(spacing: 10) {
                        Image(systemName: selectAllSymbol)
                            .foregroundStyle(selected.isEmpty ? .secondary : Color.wegaHoney)
                            .font(.system(size: 16))
                            .onTapGesture { toggleAll() }
                        Text(selected.isEmpty
                             ? trf("%@ aplikacji", "\(filtered.count)")
                             : trf("%@ zaznaczonych z %@", "\(selected.count)", "\(filtered.count)"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(tr("NAZWA · WERSJA · ŹRÓDŁO"))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                // List
                if isLoading {
                    Spacer()
                    SniffingScene(
                        caption: tr("Skanowanie aplikacji…"),
                        thoughts: [
                            tr("Co tu można wynieść?"),
                            tr("Sniff sniff… kandydat"),
                            tr("Łapię zapach Library/Caches"),
                            tr("Mhm, czy używasz tego jeszcze?"),
                            tr("Bundle ID… znajomy"),
                            tr("Kto zostawił tę apkę?"),
                            tr("Czy brew o tym wie?"),
                            tr("Mhm… stare receipty"),
                            tr("Pachnie zajętym miejscem"),
                            tr("Aport albo zostaw?")
                        ],
                        wegaSize: 110,
                        height: 150
                    )
                    .padding(.vertical, 12)
                    Spacer()
                } else if apps.isEmpty {
                    EmptyHero(
                        pose: .idle,
                        title: tr("Brak aplikacji"),
                        message: tr("Nie znaleziono żadnych zainstalowanych aplikacji.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { app in
                                let isSelected = selected.contains(app.id)
                                HStack(spacing: 12) {
                                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(isSelected ? Color.wegaHoney : .secondary)
                                        .font(.system(size: 16))
                                    AppIcon(path: app.path, size: 26)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(app.name).font(.system(size: 13, weight: .medium))
                                        if let token = app.caskToken {
                                            Text(token)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer()
                                    if let v = app.version {
                                        Text(v)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    sourceLabel(app)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(isSelected ? Color.wegaDanger.opacity(0.06) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { toggle(app.id) }

                                Divider().opacity(0.4).padding(.leading, 54)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }

            // Overlay dialog
            if showDialog {
                UninstallDialog(
                    brewCount:  selectedBrewCount,
                    trashCount: selectedTrashCount,
                    onCancel:   { showDialog = false },
                    onConfirm:  { zap in showDialog = false; Task { await uninstall(zap: zap) } }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showDialog)
        .task { await scan() }
    }

    @ViewBuilder
    private func sourceLabel(_ app: ApplicationInfo) -> some View {
        if app.isManagedByBrew {
            WegaBadge(label: "brew", variant: .brew)
        } else if app.isManagedByMas {
            WegaBadge(label: "mas", variant: .appStore)
        } else {
            WegaBadge(label: "manual", variant: .manual)
        }
    }

    private var selectAllSymbol: String {
        if selected.isEmpty { return "square" }
        if selected.count == filtered.count { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func toggleAll() {
        if selected.count == filtered.count { selected.removeAll() }
        else { selected = Set(filtered.map(\.id)) }
    }

    private func scan() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        let installedCasks = (try? await model.brewService.installedCasks()) ?? []
        let scanner = ApplicationScanner()
        var seen = Set<String>()
        var found: [ApplicationInfo] = []
        for dir in buildScanDirs() {
            let batch = (try? scanner.scanApplications(in: dir, installedCasks: installedCasks)) ?? []
            for app in batch {
                let key = app.bundleIdentifier ?? app.path.path
                if seen.insert(key).inserted { found.append(app) }
            }
        }
        apps = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uninstall(zap: Bool) async {
        isUninstalling = true; errorMessage = nil; banner = nil
        defer { isUninstalling = false }
        onWegaState?(WegaState(pose: .sniff, line: tr("Aport! Zabieram to z dysku…")))

        let targets = filtered.filter { selected.contains($0.id) }
        var succeeded: [String] = []
        var failed:    [String] = []

        for app in targets {
            if app.isManagedByBrew, let token = app.caskToken {
                do {
                    _ = try await model.brewService.uninstallCask(token: token, zap: zap)
                    succeeded.append(app.id)
                } catch {
                    do {
                        _ = try await model.brewService.uninstallCask(token: token, zap: false, force: true)
                        succeeded.append(app.id)
                    } catch { failed.append(app.name) }
                }
            } else {
                do {
                    try FileManager.default.trashItem(at: app.path, resultingItemURL: nil)
                    succeeded.append(app.id)
                } catch { failed.append(app.name) }
            }
        }

        selected.subtract(succeeded)
        await scan()

        let brewSucceeded = targets.filter { succeeded.contains($0.id) && $0.isManagedByBrew }.count
        let trashSucceeded = targets.filter { succeeded.contains($0.id) && !$0.isManagedByBrew }.count
        var parts: [String] = []
        if brewSucceeded > 0 { parts.append(trf("%@ przez brew", "\(brewSucceeded)")) }
        if trashSucceeded > 0 { parts.append(trf("%@ do Kosza", "\(trashSucceeded)")) }
        let msg = parts.joined(separator: ", ")

        if !succeeded.isEmpty {
            banner = BannerData(variant: .success, title: trf("Odinstalowano %@ aplikacji", "\(succeeded.count)"), message: msg)
            onWegaState?(WegaState(pose: .happy, line: trf("Załatwione — %@ mniej na dysku.", "\(succeeded.count)")))
        }
        if !failed.isEmpty {
            errorMessage = trf("Nie udało się: %@", "\(failed.joined(separator: ", "))")
        }
    }
}

// MARK: - Custom uninstall dialog (ZStack overlay)

private struct UninstallDialog: View {
    let brewCount:  Int
    let trashCount: Int
    let onCancel:   () -> Void
    let onConfirm:  (Bool) -> Void

    /// M3(e) — the irreversible option is never the default. `--zap` also deletes
    /// preferences, caches and Application Support; the user opts into that deliberately.
    @State private var zapMode: Bool = false

    private var totalCount: Int { brewCount + trashCount }
    private var hasMixed: Bool { brewCount > 0 && trashCount > 0 }
    private var hasNonBrew: Bool { trashCount > 0 }

    var body: some View {
        Color.black.opacity(0.5)
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 0) {
                    // Header
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11)
                                .fill(Color.wegaDanger.opacity(0.12))
                                .frame(width: 44, height: 44)
                            Image(systemName: "trash")
                                .foregroundStyle(Color.wegaDanger)
                                .font(.system(size: 18))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(trf("Odinstalować %@ %@?", "\(totalCount)", totalCount == 1 ? tr("aplikację") : tr("aplikacji")))
                                .font(.system(size: 15, weight: .semibold))
                            if hasMixed {
                                Text(trf("%@ przez brew · %@ do Kosza", "\(brewCount)", "\(trashCount)"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            } else if hasNonBrew {
                                Text(tr("Aplikacje trafią do Kosza"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(tr("Wybierz, co zostawić"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                    // Options — only shown when brew casks are selected
                    if brewCount > 0 {
                        VStack(spacing: 8) {
                            UninstallOption(
                                title:       tr("Tylko aplikacja"),
                                subtitle:    tr("Usuwa plik .app. Preferencje i cache zostają w ~/Library."),
                                command:     "brew uninstall",
                                recommended: true,
                                isSelected:  !zapMode,
                                onSelect:    { zapMode = false }
                            )
                            UninstallOption(
                                title:       tr("Aplikacja + resztki"),
                                subtitle:    tr("Zabiera też pliki w ~/Library/Preferences, Caches i Application Support. Tego nie da się cofnąć."),
                                command:     "brew uninstall --zap",
                                recommended: false,
                                isSelected:  zapMode,
                                onSelect:    { zapMode = true }
                            )
                        }
                        .padding(.horizontal, 22)
                    }

                    if hasNonBrew {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(Color.wegaInfo)
                                .font(.system(size: 13))
                            Text(trf("%@ %@ przez brew — trafi do Kosza.", "\(trashCount)", trashCount == 1 ? tr("aplikacja nie jest zarządzana") : tr("aplikacji nie jest zarządzanych")))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, brewCount > 0 ? 10 : 0)
                    }

                    // Footer buttons
                    HStack(spacing: 8) {
                        Spacer()
                        Button(tr("Anuluj"), action: onCancel)
                        Button(confirmLabel) { onConfirm(zapMode) }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.wegaDanger)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 18)
                    .background(Color.black.opacity(0.15))
                    .overlay(alignment: .top) { Divider().opacity(0.5) }
                }
                .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 40, y: 12)
                .frame(width: 480)
            }
    }

    private var confirmLabel: String {
        if brewCount > 0 {
            return zapMode ? tr("Usuń razem z resztkami") : tr("Usuń tylko aplikację")
        }
        return tr("Przenieś do Kosza")
    }
}

private struct UninstallOption: View {
    let title:       String
    let subtitle:    String
    let command:     String
    let recommended: Bool
    let isSelected:  Bool
    let onSelect:    () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.wegaHoney : Color(NSColor.controlBackgroundColor))
                        .frame(width: 16, height: 16)
                    if isSelected {
                        Circle().fill(Color.wegaInk).frame(width: 6, height: 6)
                    }
                }
                .overlay(Circle().stroke(isSelected ? Color.wegaHoney : Color.white.opacity(0.15), lineWidth: 1))
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        if recommended {
                            Text(tr("zalecane"))
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.wegaHoney)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.wegaHoney.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.wegaHoney.opacity(0.25), lineWidth: 1))
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    Text("$ \(command)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                Spacer()
            }
            .padding(14)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.wegaHoney.opacity(0.06) : Color(NSColor.controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.wegaHoney.opacity(0.32) : Color.white.opacity(0.06), lineWidth: 1))
        )
    }
}
