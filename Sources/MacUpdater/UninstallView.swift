import SwiftUI
import MacUpdaterCore

struct UninstallView: View {
    var onWegaState: ((WegaState) -> Void)?

    @EnvironmentObject private var model: AppViewModel

    @State private var apps:          [ApplicationInfo] = []
    @State private var selected:       Set<String>       = []
    @State private var search:         String            = ""
    @StateObject private var operations = UninstallCoordinator()
    @State private var showDialog:     Bool              = false
    /// UX-01: the exact visible installations named by the confirmation. Execution
    /// consumes this frozen collection instead of resolving selection through a filter
    /// for a second time after consent.
    @State private var pendingUninstallTargets: [ApplicationInfo] = []
    /// REL-14: whether the scan behind `pendingUninstallTargets` was incomplete, frozen
    /// at confirmation time so the dialog can warn that the target list may be partial.
    @State private var pendingScanIncomplete: Bool = false
    /// UX-13: `~/Library` leftovers found for the non-brew targets, planned via
    /// `MigrationPlanner` before the confirm sheet opens so it can offer them as checkboxes.
    @State private var pendingLeftoverGroups: [LeftoverGroup] = []
    /// UX-13: which leftover paths the user has ticked for the Trash. Defaults to every
    /// found item; the user opts individual files out.
    @State private var selectedLeftovers: Set<String> = []
    @State private var errorMessage:   String?
    /// REL-14: the last scan failed to read one or more sources. Distinguishes an empty
    /// machine from a failed scan and drives the incomplete-data warning before uninstall.
    @State private var scanFailed:     Bool              = false
    @State private var banner:         BannerData?
    @FocusState private var searchFocused: Bool

    private var isLoading: Bool { operations.isScanning }
    private var isUninstalling: Bool { operations.isUninstalling }

    /// REL-14: resolves the list body between loading, a failed scan, an empty machine
    /// and populated results, so a scan failure is never shown as "no apps found".
    private var listState: UninstallListState {
        UninstallListState.resolve(isLoading: isLoading, appsEmpty: apps.isEmpty, scanFailed: scanFailed)
    }

    private var filtered: [ApplicationInfo] {
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// REL-16: uninstalling is destructive, so a copy the user cannot tell apart
    /// from another must not be offered as a bare name — these rows show where
    /// the copy lives.
    private var ambiguousBundleIds: Set<String> {
        InstallationInventory.ambiguousBundleIdentifiers(apps)
    }

    private func showsLocation(_ app: ApplicationInfo) -> Bool {
        app.bundleIdentifier.map(ambiguousBundleIds.contains) ?? false
    }

    private var targets: [ApplicationInfo] {
        InstallationInventory.selected(filtered, identities: selected)
    }

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
                        Task { await presentUninstallDialog() }
                    } label: {
                        if isUninstalling { ProgressView().controlSize(.small) }
                        else { Label(targets.isEmpty ? tr("Odinstaluj") : trf("Odinstaluj (%@)", "\(targets.count)"), systemImage: "trash") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wegaDanger)
                    .disabled(targets.isEmpty || isUninstalling)
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
                        Button(action: toggleAll) {
                            Image(systemName: selectAllSymbol)
                                .foregroundStyle(targets.isEmpty ? .secondary : Color.wegaHoney)
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr("Zaznacz wszystko"))
                        .accessibilityValue(
                            trf("%@ z %@ zaznaczonych", "\(targets.count)", "\(filtered.count)")
                        )
                        Text(targets.isEmpty
                             ? trf("%@ aplikacji", "\(filtered.count)")
                             : trf("%@ zaznaczonych z %@", "\(targets.count)", "\(filtered.count)"))
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
                } else if listState == .scanFailed {
                    // REL-14: a failed scan must not read as "no apps" — say the scan failed.
                    EmptyHero(
                        pose: .idle,
                        title: tr("Skan się nie powiódł"),
                        message: tr("Nie udało się odczytać listy zainstalowanych aplikacji. Spróbuj ponownie.")
                    )
                } else if listState == .empty {
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
                                Button {
                                    toggle(app.id)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(isSelected ? Color.wegaHoney : .secondary)
                                            .font(.body)
                                        AppIcon(path: app.path, size: 26)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(app.name).font(.body.weight(.medium))
                                            if showsLocation(app) {
                                                Text(app.locationLabel)
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(Color.wegaDanger.opacity(0.85))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                            if let token = app.caskToken {
                                                Text(token)
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        Spacer()
                                        if let v = app.version {
                                            Text(v)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.tertiary)
                                        }
                                        sourceLabel(app)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(isSelected ? Color.wegaDanger.opacity(0.06) : Color.clear)
                                .accessibilityLabel(selectionAccessibilityLabel(for: app, showsLocation: showsLocation(app)))
                                .accessibilityValue(selectionAccessibilityValue(isSelected))
                                .accessibilityAddTraits(isSelected ? .isSelected : [])

                                Divider().opacity(0.4).padding(.leading, 54)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }

        }
        .sheet(isPresented: $showDialog) {
            UninstallDialog(
                targets:     pendingUninstallTargets,
                ambiguities: InstallationInventory.ambiguousBrewUninstalls(
                    selected: pendingUninstallTargets,
                    among: apps
                ),
                scanIncomplete: pendingScanIncomplete,
                leftoverGroups: pendingLeftoverGroups,
                selectedLeftovers: $selectedLeftovers,
                onCancel: cancelUninstall,
                onConfirm: confirmUninstall
            )
        }
        .onChange(of: search) { _, _ in
            selected.formIntersection(filtered.map(\.id))
        }
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
        if targets.isEmpty { return "square" }
        if targets.count == filtered.count { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func toggleAll() {
        if Set(targets.map(\.id)) == Set(filtered.map(\.id)) { selected.removeAll() }
        else { selected = Set(filtered.map(\.id)) }
    }

    /// UX-13: freezes the confirmation targets (UX-01), then plans their `~/Library`
    /// leftovers via the coordinator so the sheet opens with the checkbox list ready.
    private func presentUninstallDialog() async {
        let targets = self.targets
        guard !targets.isEmpty else { return }
        pendingUninstallTargets = targets
        pendingScanIncomplete = scanFailed
        let groups = await operations.scanLeftovers(for: targets)
        pendingLeftoverGroups = groups
        selectedLeftovers = Set(groups.flatMap { $0.items.map(\.path) })
        showDialog = true
    }

    private func cancelUninstall() {
        showDialog = false
        pendingUninstallTargets = []
        pendingScanIncomplete = false
        pendingLeftoverGroups = []
        selectedLeftovers = []
    }

    private func confirmUninstall(zap: Bool) {
        let targets = pendingUninstallTargets
        let leftovers = pendingLeftoverGroups
            .flatMap(\.items)
            .filter { selectedLeftovers.contains($0.path) }
        showDialog = false
        pendingUninstallTargets = []
        pendingScanIncomplete = false
        pendingLeftoverGroups = []
        selectedLeftovers = []
        Task { await uninstall(targets: targets, zap: zap, leftovers: leftovers) }
    }

    private func scan() async {
        errorMessage = nil
        let result = await operations.scan(using: model.brewService)
        apps = result.apps
        scanFailed = result.scanFailed
        errorMessage = result.failures.scanErrorMessage
    }

    private func uninstall(targets: [ApplicationInfo], zap: Bool, leftovers: [URL]) async {
        guard !targets.isEmpty else { return }
        // REL-06 — `brew uninstall --cask` (with `--zap` it also deletes preferences and
        // Application Support) rewrites the Caskroom, and `UpgradeMutex` only covers upgrades.
        // Without a ticket a quit here ends the process between the Caskroom entry and the
        // bundle, which is the half-removed state the guard exists to prevent.
        let ticket = MutationGuard.shared.begin(trf("dezinstalacja %@ aplikacji", "\(targets.count)"))
        defer { MutationGuard.shared.end(ticket) }

        errorMessage = nil; banner = nil
        onWegaState?(WegaState(pose: .sniff, line: tr("Aport! Zabieram to z dysku…")))

        let outcome = await operations.uninstall(
            targets: targets,
            zap: zap,
            leftovers: leftovers,
            using: model.brewService
        )
        let succeeded = outcome.succeeded
        var failed: [(name: String, requestedZap: Bool)] = []
        for app in targets where outcome.failedIDs.contains(app.id) {
            if app.isManagedByBrew {
                failed.append((app.name, zap))
            } else {
                failed.append((app.name, false))
            }
        }

        selected.subtract(succeeded)
        await scan()

        let brewSucceeded = targets.filter { succeeded.contains($0.id) && $0.isManagedByBrew }.count
        let trashSucceeded = targets.filter { succeeded.contains($0.id) && !$0.isManagedByBrew }.count
        var parts: [String] = []
        if brewSucceeded > 0 { parts.append(trf("%@ przez brew", "\(brewSucceeded)")) }
        if trashSucceeded > 0 { parts.append(trf("%@ do Kosza", "\(trashSucceeded)")) }
        // UX-13: report the leftovers that reached the Trash alongside the app removals.
        if outcome.leftoversTrashed > 0 { parts.append(trf("%@ resztek do Kosza", "\(outcome.leftoversTrashed)")) }
        let msg = parts.joined(separator: ", ")

        if !succeeded.isEmpty {
            banner = BannerData(variant: .success, title: trf("Odinstalowano %@ aplikacji", "\(succeeded.count)"), message: msg)
            onWegaState?(WegaState(pose: .happy, line: trf("Załatwione — %@ mniej na dysku.", "\(succeeded.count)")))
        }
        if !failed.isEmpty {
            errorMessage = trf(
                "Odinstalowanie niepełne — nie usunięto: %@",
                "\(failed.map(\.name).joined(separator: ", "))"
            )
            if failed.contains(where: \.requestedZap) {
                errorMessage? += " " + tr("Nie uruchomiono --force; wybrane usunięcie wraz z resztkami nie zostało po cichu zmienione.")
            }
        }
        // UX-13: leftovers that could not be moved are surfaced, not swallowed.
        if outcome.leftoversFailed > 0 {
            let note = trf("Nie udało się przenieść %@ resztek do Kosza.", "\(outcome.leftoversFailed)")
            errorMessage = [errorMessage, note].compactMap { $0 }.joined(separator: " ")
        }
    }
}

// MARK: - Native uninstall sheet

struct UninstallDialog: View {
    let targets: [ApplicationInfo]
    /// REL-16: casks whose application is installed in more than one place — see
    /// `InstallationInventory.ambiguousBrewUninstalls`.
    let ambiguities: [AmbiguousBrewUninstall]
    /// REL-14: the scan behind these targets failed to read one or more sources, so the
    /// list may be missing installations. The dialog warns before the destructive action.
    var scanIncomplete: Bool = false
    /// UX-13: the `~/Library` leftovers planned for the non-brew targets, presented as
    /// checkboxes so the user reviews exactly what "app + leftovers" removes.
    var leftoverGroups: [LeftoverGroup] = []
    /// UX-13: the leftover paths the user has ticked for the Trash. Bound to the caller so
    /// the confirmed selection survives the sheet dismissal.
    @Binding var selectedLeftovers: Set<String>
    let onCancel:   () -> Void
    let onConfirm:  (Bool) -> Void

    init(
        targets: [ApplicationInfo],
        ambiguities: [AmbiguousBrewUninstall],
        scanIncomplete: Bool = false,
        leftoverGroups: [LeftoverGroup] = [],
        selectedLeftovers: Binding<Set<String>> = .constant([]),
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Bool) -> Void
    ) {
        self.targets = targets
        self.ambiguities = ambiguities
        self.scanIncomplete = scanIncomplete
        self.leftoverGroups = leftoverGroups
        self._selectedLeftovers = selectedLeftovers
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    /// M3(e) — the irreversible option is never the default. `--zap` also deletes
    /// preferences, caches and Application Support; the user opts into that deliberately.
    @State private var zapMode: Bool = false

    private var brewCount: Int { targets.filter(\.isManagedByBrew).count }
    private var trashCount: Int { targets.count - brewCount }
    private var totalCount: Int { targets.count }
    private var hasMixed: Bool { brewCount > 0 && trashCount > 0 }
    private var hasNonBrew: Bool { trashCount > 0 }

    var body: some View {
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

            ScrollView {
                VStack(spacing: 0) {
                    if scanIncomplete {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.wegaDanger)
                                .font(.system(size: 13))
                            Text(tr("Skan aplikacji był niekompletny — lista celów może nie zawierać wszystkich instalacji. Zweryfikuj przed usunięciem."))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(
                            Color.wegaDanger.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.wegaDanger.opacity(0.28), lineWidth: 1)
                        )
                        .padding(.horizontal, 22)
                        .padding(.bottom, 12)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("Dokładne cele"))
                            .font(.system(size: 12, weight: .semibold))
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(targets) { app in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).font(.system(size: 12, weight: .medium))
                                    Text(app.path.path)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        Color(NSColor.controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)

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

                    if !ambiguities.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(ambiguities) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(Color.wegaDanger)
                                        .font(.system(size: 13))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tr("Homebrew usunie swoją kopię"))
                                            .font(.system(size: 12, weight: .semibold))
                                        Text(trf(
                                            "%@ jest zainstalowany w %@ miejscach: %@. Homebrew usunie kopię, którą sam zarządza (brew uninstall %@) — niekoniecznie tę zaznaczoną.",
                                            "\(item.appName)",
                                            "\(item.locations.count)",
                                            "\(item.locations.joined(separator: ", "))",
                                            "\(item.caskToken)"
                                        ))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(12)
                        .background(
                            Color.wegaDanger.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.wegaDanger.opacity(0.28), lineWidth: 1)
                        )
                        .padding(.horizontal, 22)
                        .padding(.top, brewCount > 0 ? 12 : 0)
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

                    // UX-13: "app + leftovers" for non-brew apps — the same `~/Library`
                    // items brew would clear with `--zap`, presented so the user reviews
                    // and consents before they go to the (recoverable) Trash.
                    if !leftoverGroups.isEmpty {
                        UninstallLeftoverSelection(
                            groups: leftoverGroups,
                            selected: $selectedLeftovers
                        )
                        .padding(.horizontal, 22)
                        .padding(.top, 12)
                    }
                }
            }
            .frame(minHeight: 240, idealHeight: 480, maxHeight: 560)

            // Footer buttons
            HStack(spacing: 8) {
                Spacer()
                Button(tr("Anuluj"), role: .cancel) {
                    UninstallDialogKeyboardBehavior.perform(
                        .cancel,
                        zapMode: zapMode,
                        onCancel: onCancel,
                        onConfirm: onConfirm
                    )
                }
                .keyboardShortcut(.cancelAction)
                Button(confirmLabel, role: .destructive) {
                    UninstallDialogKeyboardBehavior.perform(
                        .confirm,
                        zapMode: zapMode,
                        onCancel: onCancel,
                        onConfirm: onConfirm
                    )
                }
                .keyboardShortcut(.defaultAction)
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

    private var confirmLabel: String {
        if brewCount > 0 {
            return zapMode ? tr("Usuń razem z resztkami") : tr("Usuń tylko aplikację")
        }
        return tr("Przenieś do Kosza")
    }
}

struct UninstallOption: View {
    let title:       String
    let subtitle:    String
    let command:     String
    let recommended: Bool
    let isSelected:  Bool
    let onSelect:    () -> Void

    var body: some View {
        let semantics = UninstallOptionAccessibilitySemantics(
            title: title,
            isSelected: isSelected
        )
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
        .accessibilityLabel(semantics.label)
        .accessibilityValue(semantics.value)
        .accessibilityAddTraits(semantics.isSelected ? .isSelected : [])
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.wegaHoney.opacity(0.06) : Color(NSColor.controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.wegaHoney.opacity(0.32) : Color.white.opacity(0.06), lineWidth: 1))
        )
    }
}

// MARK: - UX-13 leftover selection

/// The checkbox sheet section listing the `~/Library` leftovers found for the non-brew
/// targets, grouped per app. Selection is bound to the caller; every item defaults to
/// checked, and the copy makes clear the files go to the recoverable Trash.
struct UninstallLeftoverSelection: View {
    let groups: [LeftoverGroup]
    @Binding var selected: Set<String>

    private var allPaths: [String] { groups.flatMap { $0.items.map(\.path) } }
    private var allSelected: Bool { !allPaths.isEmpty && selected.isSuperset(of: allPaths) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.minus")
                    .foregroundStyle(Color.wegaHoney)
                    .font(.system(size: 13))
                Text(tr("Resztki w ~/Library"))
                    .font(.system(size: 12, weight: .semibold))
                Text("\(allPaths.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(allSelected ? tr("Odznacz wszystko") : tr("Zaznacz wszystko")) {
                    if allSelected { selected.subtract(allPaths) }
                    else { selected.formUnion(allPaths) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.wegaHoney)
            }
            Text(tr("Zaznaczone pliki trafią do Kosza — możesz je stamtąd przywrócić."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if groups.count > 1 {
                        Text(group.app.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group.items, id: \.path) { url in
                        UninstallLeftoverRow(
                            url: url,
                            isOn: selected.contains(url.path),
                            toggle: { toggle(url.path) }
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(
            Color(NSColor.controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private func toggle(_ path: String) {
        if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
    }
}

private struct UninstallLeftoverRow: View {
    let url: URL
    let isOn: Bool
    let toggle: () -> Void

    private var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.wegaHoney : .secondary)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                    Text(displayPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(displayPath)
        .accessibilityValue(selectionAccessibilityValue(isOn))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
