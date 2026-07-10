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
                        if x.isManagedByBrew { return 0 }
                        return x.isManagedByMas ? 1 : 2
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
                InventoryStatCard(label: "Homebrew",  value: brewCount,        sublabel: tr("cask + formula"), color: .wegaHoney,  active: filter == .brew)      { setFilter(.brew) }
                InventoryStatCard(label: "App Store", value: masCount,         sublabel: tr("ze sklepu"),      color: .wegaInfo,   active: filter == .appStore)   { setFilter(.appStore) }
                InventoryStatCard(label: tr("Ręcznie"),   value: manualCount,      sublabel: tr("poza brew/mas"),  color: .wegaDanger, active: filter == .manual)     { setFilter(.manual) }
                InventoryStatCard(label: "npm -g",    value: npmGlobals.count, sublabel: "CLI",            color: .wegaInfo,   active: false)                 { /* npm globals are informational only — not a filter target, so tapping is a deliberate no-op */ }
                InventoryStatCard(label: tr("Razem"),     value: apps.count,       sublabel: tr("wszystkie"),      color: .primary,    active: filter == .all)        { setFilter(.all) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            // Toolbar
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 13))
                    TextField(tr("Szukaj po nazwie lub bundle ID…"), text: $search)
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

                Text(trf("%@ z %@", "\(filtered.count)", "\(apps.count)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Button { Task { await scan() } } label: {
                    Label(tr("Odśwież"), systemImage: "arrow.clockwise")
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
                ProportionalHStack(weights: InventoryRow.columnWeights, spacing: InventoryRow.columnSpacing) {
                    SortHeaderCell(label: tr("Aplikacja"),   key: .name,       sortKey: $sortKey, sortAsc: $sortAsc)
                    SortHeaderCell(label: tr("Wersja"),      key: .version,    sortKey: $sortKey, sortAsc: $sortAsc)
                    SortHeaderCell(label: "Bundle ID",   key: .bundleId,   sortKey: $sortKey, sortAsc: $sortAsc)
                    SortHeaderCell(label: tr("Źródło"),      key: .source,     sortKey: $sortKey, sortAsc: $sortAsc)
                    SortHeaderCell(label: tr("Aktualizacja"),key: .updateDate, sortKey: $sortKey, sortAsc: $sortAsc)
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
                            caption: tr("Obchód wszystkich kątów…"),
                            thoughts: [
                                tr("Sniff sniff… ile tego"),
                                tr("Bundle ID… mhm"),
                                tr("Kto tu zarządza?"),
                                tr("Brew, MAS czy ręcznie?"),
                                tr("Łapię zapach Info.plist"),
                                tr("Czy widzę ten cask w bazie?"),
                                tr("Globalne npm pachną odwiecznością"),
                                "0x4A 0x65 0x6C 0x6C 0x79",
                                tr("Mhm, jeszcze ten folder"),
                                tr("Przeczesuję /Applications…")
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
        onWegaState?(WegaState(pose: .sniff, line: tr("Obchód wszystkich kątów…")))

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

        onWegaState?(WegaState(pose: .happy, line: trf("Obchód skończony — %@ aplikacji pod opieką.", "\(apps.count)")))
    }
}

private struct NpmGlobalsList: View {
    let packages: [NpmGlobalPackage]

    var body: some View {
        WegaCard(padded: false) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox").foregroundStyle(Color.wegaInfo)
                Text(tr("npm globalne")).font(.system(size: 13, weight: .semibold))
                Text("\(packages.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                Text(tr("instalacje przez `npm i -g`")).font(.system(size: 11)).foregroundStyle(.tertiary)
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
        case 0:  return tr("dzisiaj")
        case 1:  return tr("wczoraj")
        default: return trf("%@ dni temu", "\(days)")
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
                    Text(tr(opt.rawValue))
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct InventoryRow: View {
    let app:   ApplicationInfo
    let isAlt: Bool

    @State private var hovered = false

    /// Column weights, shared with the table header so the two never drift apart.
    static let columnWeights: [CGFloat] = [1.6, 0.6, 1.2, 0.8, 1.2]
    static let columnSpacing: CGFloat = 12

    /// Row background: hover wins, otherwise alternating rows get a faint tint.
    private var rowBackground: Color {
        if hovered { return Color.wegaHoney.opacity(0.04) }
        return isAlt ? Color.white.opacity(0.012) : Color.clear
    }

    var body: some View {
        ProportionalHStack(weights: Self.columnWeights, spacing: Self.columnSpacing) {
            // Name
            HStack(spacing: 9) {
                AppIcon(path: app.path, size: 22)
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Version
            Text(app.version ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Bundle ID
            Text(app.bundleIdentifier ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Source — classified by the SAME `AppOrigin` the Updates window
            // groups by, so the two windows can never disagree about an app's origin.
            HStack(spacing: 6) {
                switch AppOrigin.of(app) {
                case .brew:
                    WegaBadge(label: "Brew", variant: .brew)
                    if let token = app.caskToken {
                        Text(token)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .lineLimit(1)
                    }
                case .appStore:
                    WegaBadge(label: "App Store", variant: .appStore)
                    if let id = app.masAppID {
                        Text(id)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .lineLimit(1)
                    }
                case .npm, .manual:
                    WegaBadge(label: tr("Ręcznie"), variant: .manual)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Update date
            UpdateDateCell(date: app.updateDate)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(rowBackground)
        .onHover { hovered = $0 }
    }
}

/// Lays out its subviews side by side with widths proportional to `weights` (M5).
///
/// Replaces `.frame(maxWidth: .infinity * weight)`, which reads like proportional sizing
/// but is not: `infinity * 1.6` and `infinity * 0.6` are the same number, so every column
/// asked for the same unbounded width and the stack split the row evenly.
struct ProportionalHStack: Layout {
    let weights: [CGFloat]
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = ColumnLayout.proportionalWidths(total: bounds.width, weights: weights, spacing: spacing)
        guard widths.count == subviews.count else {
            // Weight/subview mismatch is a programming error; fall back to equal columns
            // rather than dropping views on the floor.
            let equal = ColumnLayout.proportionalWidths(
                total: bounds.width, weights: subviews.map { _ in 1 }, spacing: spacing)
            place(subviews, widths: equal, in: bounds)
            return
        }
        place(subviews, widths: widths, in: bounds)
    }

    private func place(_ subviews: Subviews, widths: [CGFloat], in bounds: CGRect) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }
}
