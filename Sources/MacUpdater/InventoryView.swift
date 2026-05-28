import SwiftUI
import MacUpdaterCore

private enum SourceFilter: String, CaseIterable {
    case all      = "Wszystkie"
    case brew     = "Brew"
    case appStore = "App Store"
    case manual   = "Ręcznie"
}

private enum SortKey: String { case name, version, bundleId, source, updateDate }

struct InventoryView: View {
    var onWegaState: ((WegaState) -> Void)?

    @EnvironmentObject private var model: AppViewModel

    @State private var apps:         [ApplicationInfo] = []
    @State private var npmGlobals:   [NpmGlobalPackage] = []
    @State private var isScanning:   Bool              = false
    @State private var errorMessage: String?
    @State private var search:       String            = ""
    @State private var filter:       SourceFilter      = .all
    @State private var sortKey:      SortKey           = .name
    @State private var sortAsc:      Bool              = true
    @FocusState private var searchFocused: Bool

    private var brewCount:   Int { apps.filter(\.isManagedByBrew).count }
    private var masCount:    Int { apps.filter(\.isManagedByMas).count }
    private var manualCount: Int { apps.count - brewCount - masCount }

    private var filtered: [ApplicationInfo] {
        apps
            .filter { app in
                switch filter {
                case .all:      true
                case .brew:     app.isManagedByBrew
                case .appStore: app.isManagedByMas
                case .manual:   !app.isManagedByBrew && !app.isManagedByMas
                }
            }
            .filter { app in
                guard !search.isEmpty else { return true }
                return app.name.localizedCaseInsensitiveContains(search)
                    || (app.bundleIdentifier?.localizedCaseInsensitiveContains(search) ?? false)
            }
            .sorted { a, b in
                let cmp: Bool
                switch sortKey {
                case .name:     cmp = a.name < b.name
                case .version:  cmp = (a.version ?? "") < (b.version ?? "")
                case .bundleId: cmp = (a.bundleIdentifier ?? "") < (b.bundleIdentifier ?? "")
                case .source:
                    func rank(_ x: ApplicationInfo) -> Int {
                        x.isManagedByBrew ? 0 : (x.isManagedByMas ? 1 : 2)
                    }
                    cmp = rank(a) < rank(b)
                case .updateDate:
                    cmp = (a.updateDate ?? .distantPast) < (b.updateDate ?? .distantPast)
                }
                return sortAsc ? cmp : !cmp
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Stat cards
            HStack(spacing: 10) {
                InventoryStatCard(label: "Homebrew",  value: brewCount,        sublabel: "cask + formula", color: .wegaHoney,  active: filter == .brew)      { setFilter(.brew) }
                InventoryStatCard(label: "App Store", value: masCount,         sublabel: "ze sklepu",      color: .wegaInfo,   active: filter == .appStore)   { setFilter(.appStore) }
                InventoryStatCard(label: "Ręcznie",   value: manualCount,      sublabel: "poza brew/mas",  color: .wegaDanger, active: filter == .manual)     { setFilter(.manual) }
                InventoryStatCard(label: "npm -g",    value: npmGlobals.count, sublabel: "CLI",            color: .wegaInfo,   active: false)                 { }
                InventoryStatCard(label: "Razem",     value: apps.count,       sublabel: "wszystkie",      color: .primary,    active: filter == .all)        { setFilter(.all) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            // Toolbar
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 13))
                    TextField("Szukaj po nazwie lub bundle ID…", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($searchFocused)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08), lineWidth: 1))
                .frame(width: 240)
                .onTapGesture { searchFocused = true }

                FilterPills(selection: $filter)

                Spacer()

                Text("\(filtered.count) z \(apps.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Button { Task { await scan() } } label: {
                    Label("Odśwież", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(isScanning)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if let err = errorMessage {
                ErrorBanner(message: err).padding(.horizontal, 16).padding(.bottom, 8)
            }

            // Table header
            WegaCard(padded: false) {
                HStack(spacing: 12) {
                    SortHeaderCell(label: "Aplikacja",   key: .name,       sortKey: $sortKey, sortAsc: $sortAsc, flex: 1.6)
                    SortHeaderCell(label: "Wersja",      key: .version,    sortKey: $sortKey, sortAsc: $sortAsc, flex: 0.6)
                    SortHeaderCell(label: "Bundle ID",   key: .bundleId,   sortKey: $sortKey, sortAsc: $sortAsc, flex: 1.2)
                    SortHeaderCell(label: "Źródło",      key: .source,     sortKey: $sortKey, sortAsc: $sortAsc, flex: 0.8)
                    SortHeaderCell(label: "Aktualizacja",key: .updateDate, sortKey: $sortKey, sortAsc: $sortAsc, flex: 1.2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.wegaHoney.opacity(0.02))
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                // Rows
                if isScanning {
                    HStack {
                        Spacer()
                        SniffingScene(
                            caption: "Obchód wszystkich kątów…",
                            thoughts: [
                                "Sniff sniff… ile tego",
                                "Bundle ID… mhm",
                                "Kto tu zarządza?",
                                "Brew, MAS czy ręcznie?",
                                "Łapię zapach Info.plist",
                                "Czy widzę ten cask w bazie?",
                                "Globalne npm pachną odwiecznością",
                                "0x4A 0x65 0x6C 0x6C 0x79",
                                "Mhm, jeszcze ten folder",
                                "Przeczesuję /Applications…"
                            ],
                            wegaSize: 110,
                            height: 150
                        )
                        .padding(.vertical, 12)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered.indices, id: \.self) { i in
                                let app = filtered[i]
                                InventoryRow(app: app, isAlt: i % 2 == 1)
                                Divider().opacity(0.3)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            if !npmGlobals.isEmpty {
                NpmGlobalsList(packages: npmGlobals)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .task { await scan() }
    }

    private func setFilter(_ f: SourceFilter) { filter = filter == f ? .all : f }

    private func scan() async {
        isScanning = true; errorMessage = nil
        defer { isScanning = false }
        onWegaState?(WegaState(pose: .sniff, line: "Obchód wszystkich kątów…"))

        let installedCasks: Set<String>
        do { installedCasks = try await model.brewService.installedCasks() }
        catch { installedCasks = [] }

        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(AppMetadata.bundleIdentifier)/casks.json")
        let casks = (try? await CaskDatabaseClient(cache: CaskDatabaseCache(fileURL: cacheURL)).fetchCasks()) ?? []

        let scanner = ApplicationScanner()
        var seen = Set<String>()
        var all:  [ApplicationInfo] = []
        for dir in buildScanDirs() {
            let found = (try? scanner.scanApplications(in: dir, installedCasks: installedCasks, availableCasks: casks)) ?? []
            for app in found {
                let key = app.bundleIdentifier ?? app.path.path
                if seen.insert(key).inserted { all.append(app) }
            }
        }
        var sorted = all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Populate masAppID for App Store apps (graceful: skip if mas unavailable)
        // Only call masService if we have MAS apps to correlate
        if sorted.contains(where: \.isManagedByMas) {
            let masApps = (try? await model.masService.list()) ?? []
            if !masApps.isEmpty {
                let masIndex = masApps.reduce(into: [:]) { dict, app in
                    dict[StringNormalizer.normalize(app.name)] = app.appStoreID
                }
                sorted = sorted.map { app in
                    guard app.isManagedByMas, app.masAppID == nil else { return app }
                    var updated = app
                    updated.masAppID = masIndex[StringNormalizer.normalize(app.name)]
                    return updated
                }
            }
        }

        apps = sorted
        npmGlobals = (try? await model.npmService.installedGlobals()) ?? []

        onWegaState?(WegaState(pose: .happy, line: "Obchód skończony — \(apps.count) aplikacji pod opieką."))
    }
}

private struct NpmGlobalsList: View {
    let packages: [NpmGlobalPackage]

    var body: some View {
        WegaCard(padded: false) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox").foregroundStyle(Color.wegaInfo)
                Text("npm globalne").font(.system(size: 13, weight: .semibold))
                Text("\(packages.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                Text("instalacje przez `npm i -g`").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }

            ForEach(packages, id: \.name) { pkg in
                HStack(spacing: 12) {
                    Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 22)
                    Text(pkg.name)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(pkg.installedVersion)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                if pkg.name != packages.last?.name {
                    Divider().opacity(0.3).padding(.leading, 46)
                }
            }
        }
    }
}

private struct UpdateDateCell: View {
    let date: Date?

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func label(for date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0
        switch days {
        case 0:  return "dzisiaj"
        case 1:  return "wczoraj"
        default: return "\(days) dni temu"
        }
    }

    private func color(for date: Date) -> Color {
        let days = Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0
        if days >= 90 { return Color.wegaDanger }
        if days >= 60 { return .orange }
        return .secondary
    }

    var body: some View {
        if let date {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.dateFmt.string(from: date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(color(for: date))
                Text(label(for: date))
                    .font(.system(size: 10))
                    .foregroundStyle(color(for: date).opacity(0.7))
            }
        } else {
            Text("—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
    }
}

private struct InventoryStatCard: View {
    let label:    String
    let value:    Int
    let sublabel: String
    let color:    Color
    let active:   Bool
    let onTap:    () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Text("\(value)")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(active ? color : .primary)
                Text(sublabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? color.opacity(0.06) : Color(NSColor.controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? color.opacity(0.30) : Color.white.opacity(0.06), lineWidth: 1))
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .opacity(active ? 1 : 0.4)
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct FilterPills: View {
    @Binding var selection: SourceFilter

    var body: some View {
        HStack(spacing: 1) {
            ForEach(SourceFilter.allCases, id: \.self) { opt in
                let active = selection == opt
                Button { selection = opt } label: {
                    Text(opt.rawValue)
                        .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? .primary : .secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(active ? Color(NSColor.controlBackgroundColor) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .shadow(color: active ? .black.opacity(0.25) : .clear, radius: 1, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

private struct SortHeaderCell: View {
    let label:   String
    let key:     SortKey
    @Binding var sortKey: SortKey
    @Binding var sortAsc: Bool
    var flex:    CGFloat = 1

    var body: some View {
        Button {
            if sortKey == key { sortAsc.toggle() }
            else { sortKey = key; sortAsc = true }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(sortKey == key ? Color.wegaHoney : Color.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                if sortKey == key {
                    Image(systemName: sortAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.wegaHoney)
                }
            }
            .frame(maxWidth: .infinity * flex, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct InventoryRow: View {
    let app:   ApplicationInfo
    let isAlt: Bool

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Name (flex 1.6)
            HStack(spacing: 9) {
                AppIcon(path: app.path, size: 22)
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity * 1.6, alignment: .leading)

            // Version (flex 0.6)
            Text(app.version ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity * 0.6, alignment: .leading)

            // Bundle ID (flex 1.2)
            Text(app.bundleIdentifier ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity * 1.2, alignment: .leading)

            // Source (flex 0.8)
            HStack(spacing: 6) {
                if app.isManagedByBrew {
                    WegaBadge(label: "Brew", variant: .brew)
                    if let token = app.caskToken {
                        Text(token)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .lineLimit(1)
                    }
                } else if app.isManagedByMas {
                    WegaBadge(label: "App Store", variant: .appStore)
                    if let id = app.masAppID {
                        Text(id)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .lineLimit(1)
                    }
                } else {
                    WegaBadge(label: "Ręcznie", variant: .manual)
                }
            }
            .frame(maxWidth: .infinity * 0.8, alignment: .leading)

            // Update date (flex 1.2)
            UpdateDateCell(date: app.updateDate)
                .frame(maxWidth: .infinity * 1.2, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(hovered ? Color.wegaHoney.opacity(0.04) : (isAlt ? Color.white.opacity(0.012) : Color.clear))
        .onHover { hovered = $0 }
    }
}
