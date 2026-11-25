import SwiftUI
import MacUpdaterCore

// Supporting views for `UpdateView`, split out to keep `UpdateView.swift` within
// SwiftLint's file_length budget. Module-internal (not `private`) so `UpdateView`
// in its own file can reference them.

struct RestartSection: View {
    let candidates:   [RestartInfo]
    let busyProcess:  String?
    let onRestart:    (RestartInfo) -> Void
    let pendingForce: RestartInfo?
    let onForce:      (RestartInfo) -> Void
    let onKeepOpen:   (RestartInfo) -> Void
    /// The alert went away without either button. Not `onKeepOpen`: SwiftUI also sets the
    /// binding to `false` after „Wymuś zamknięcie”, and that must not record a refusal.
    var onDismissForcePrompt: (RestartInfo) -> Void = { _ in }

    /// A dismissal leaves the app open, as „Zostaw otwartą” does, and clears the prompt
    /// instead of leaving it pending behind a closed alert.
    var forcePromptPresented: Binding<Bool> {
        Binding(get: { pendingForce != nil }, set: { shown in
            if !shown, let info = pendingForce { onDismissForcePrompt(info) }
        })
    }

    var body: some View {
        WegaCard {
            WegaCardHeader(icon: "arrow.clockwise.circle", title: tr("Do restartu"),
                           count: candidates.count,
                           note: tr("były otwarte podczas aktualizacji"))

            ForEach(candidates, id: \.processName) { info in
                HStack(spacing: 12) {
                    PackageLetterIcon(name: info.appName, size: 32)
                    Text(info.appName).font(.wega(.body, weight: .medium))
                    Spacer()
                    Button { onRestart(info) } label: {
                        if busyProcess == info.processName {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(tr("Uruchom ponownie"), systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.small)
                    .disabled(busyProcess != nil)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    if info.processName != candidates.last?.processName {
                        Divider().opacity(0.4).padding(.leading, 54)
                    }
                }
            }
        }
        .alert(
            trf("%@ nie chce się zamknąć.", pendingForce?.appName ?? ""),
            isPresented: forcePromptPresented,
            presenting: pendingForce
        ) { info in
            // No shortcut on either button: the cancel role gives this one Escape and the
            // destructive one gets no key, so Return never forces (checked on macOS 27).
            Button(tr("Zostaw otwartą"), role: .cancel) { onKeepOpen(info) }
            Button(tr("Wymuś zamknięcie"), role: .destructive) { onForce(info) }
        } message: { _ in
            Text(tr("Wymuszenie może stracić niezapisaną pracę."))
        }
    }
}

struct BrewLogPanel: View {
    let lines:   [String]
    /// Answers Homebrew's tap-trust warning with buttons above the log. `nil` where a click
    /// could not run anyway — the run's log, while the update holds the brew mutex.
    var tapTrust: TapTrustActions? = nil
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tapTrustPlan: [TapTrustRemedy] = []

    /// Taps named by the warning in the log; the receipts are read again only when these change.
    private var untrustedTaps: [String] {
        tapTrust == nil ? [] : TapTrustWarning.untrustedTaps(in: lines)
    }

    var body: some View {
        WegaCard(padded: false) {
            header

            if let tapTrust {
                let pending = TapTrustPlanner.pending(tapTrustPlan, in: lines)
                if !pending.isEmpty {
                    TapTrustNotice(remedies: pending, run: tapTrust.run)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.wega(.footnote, monospaced: true))
                                .foregroundStyle(line.hasPrefix("$") ? Color.wegaHoney : Color.primary.opacity(0.75))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .frame(maxHeight: 220)
                .onChange(of: lines.count) { _, _ in
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .task(id: untrustedTaps) {
            let taps = untrustedTaps
            tapTrustPlan = []
            guard let tapTrust, !taps.isEmpty else { return }
            tapTrustPlan = await tapTrust.resolve(taps)
        }
    }

    /// The title row with the close button. Internal so the layout tests can measure it.
    var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.wegaSuccess).frame(width: 6, height: 6)
            Text("brew log")
                .font(.wega(.footnote, weight: .semibold, monospaced: true))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.wega(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The 28 pt hit area overhangs the header's padding rather than making it taller:
            // 12 pt of layout stays under the title's line.
            .padding(.vertical, -8)
            .accessibilityLabel(tr("Zamknij"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}

struct CheckingBar: View {
    let command: String
    let delay:   Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(Color.wegaHoney)
            Text("$ \(command)")
                .font(.wega(.callout, monospaced: true))
                .foregroundStyle(.secondary)
            Spacer()
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.wegaHoney.opacity(0.15))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    // UX-03 — the sweeping fill is decoration: it reports no progress the
                    // spinner and the command line beside it do not already report. With
                    // "Ogranicz ruch" on it is dropped rather than frozen at full width,
                    // which would read as "finished".
                    if !reduceMotion {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LinearGradient(colors: [Color.wegaToffee, Color.wegaHoney], startPoint: .leading, endPoint: .trailing))
                            .frame(width: visible ? .infinity : 0)
                            .animation(
                                ContinuousMotion.forever(
                                    .linear(duration: 2),
                                    autoreverses: false,
                                    reduceMotion: reduceMotion
                                ),
                                value: visible
                            )
                    }
                }
                .frame(width: 160)
        }
        .opacity(visible ? 1 : 0)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { visible = true }
        }
    }
}

struct UpdateSection: View {
    let title:     String
    var subtitle:  String? = nil
    var tint:      Color
    /// UX-18 — the group's number, set only in urgency grouping.
    var ordinal:   Int? = nil
    let items:     [OutdatedItem]
    var iconPaths: [String: URL]  = [:]
    /// M5 — rollback coverage per cask token. Empty for sections where the question does
    /// not apply (formulae, npm, App Store), which leaves the rows unbadged.
    var rollbackProtection: [String: RollbackProtection.Verdict] = [:]
    /// LT-01 — sources Wega cannot roll back say so under their header, instead of
    /// letting the cask shield imply a safety net the other sections do not have.
    var rollbackCaption: String? = nil
    /// UX-18 — a card grouped by urgency mixes sources, so each row names its source and,
    /// where the rollback net cannot reach it, says so itself (LT-01 on the row).
    var showsSource = false
    @Binding var selected: Set<String>
    var inspectedKey: String? = nil
    var onIgnore: ((OutdatedItem) -> Void)?
    var onPin:    ((OutdatedItem) -> Void)?
    var onSkip:   ((OutdatedItem) -> Void)? = nil
    var onInspect: ((OutdatedItem) -> Void)? = nil

    @FocusState private var focusedKey: String?
    @Environment(\.updatesOnScreen) private var onScreen
    /// C2 §4.6 — the running update, when there is one: row statuses and the batches' notes.
    @Environment(\.updateRun) private var run
    /// False while a run or a scan in place disables the list. `.disabled` alone was never shown
    /// to keep a focusable row out of the Tab loop, so the rows lose their Tab stops with it.
    @Environment(\.isEnabled) private var isEnabled
    /// UXP-21 — the row Tab lands on. Kept apart from `focusedKey`, which empties once focus
    /// leaves the rows themselves (another group, or this row's ⋯ when it takes focus), so the
    /// stop stays where the user left it.
    @State private var tabStop: String?

    /// A skip closure only when there is a concrete version on offer to skip.
    private func skipAction(for item: OutdatedItem) -> (() -> Void)? {
        guard let onSkip, let to = item.to, !to.isEmpty else { return nil }
        return { onSkip(item) }
    }

    /// How much of this section is ticked, ignoring every row outside it.
    private var groupState: SelectAllState {
        UpdatePlanner.groupSelectionState(selected: selected, groupKeys: items.map(\.key))
    }

    var body: some View {
        WegaCard {
            UpdateGroupHeader(title: title, tint: tint, ordinal: ordinal, count: items.count,
                              note: subtitle, runNote: run?.laneNote(for: Set(items.map(\.kind))), caption: rollbackCaption,
                              selection: SelectionCheckbox(
                                  state: groupState,
                                  accessibilityLabel: trf("Zaznacz całą grupę: %@", title),
                                  accessibilityValue: trf("%@ z %@ zaznaczonych",
                                                          "\(items.filter { selected.contains($0.key) }.count)",
                                                          "\(items.count)"),
                                  toggle: { toggleGroup() }
                              ))

            let keys = items.map(\.key)
            ForEach(items) { item in
                VStack(spacing: 0) {
                    PackageRow(
                        name:           item.kind == .cask
                            ? CaskDisplayName.name(token: item.name, appPath: iconPaths[item.name])
                            : item.name,
                        token:          item.kind == .cask ? item.name : nil,
                        iconPath:       iconPaths[item.name],
                        currentVersion: item.from,
                        latestVersion:  item.to,
                        isSelected:     selected.contains(item.key),
                        isInspected:    item.key == inspectedKey,
                        rollback:       rollbackProtection[item.name],
                        source:         showsSource ? (item.kind == .cask ? "Homebrew" : item.kind.sourceLabel) : nil,
                        rollbackUnavailableReason: showsSource ? UpdateView.rollbackCaption(for: item.kind) : nil,
                        runStatus: run?.rowStatus(for: item),
                        runIsStopping: run?.isStopping ?? false,
                        onToggle:       { toggle(item.key) },
                        onSelect:       { focus(item.key); onInspect?(item) },
                        onIgnore:       { onIgnore?(item) },
                        onPin:          { onPin?(item) },
                        onSkip:         skipAction(for: item),
                        backgroundUpdateToken: item.kind == .cask ? item.name : nil,
                        isTabStop:      UpdateRowFocus.isTabStop(item.key, in: keys, focused: tabStop, onScreen: onScreen && isEnabled),
                        onMove:         { move(from: item.key, in: keys, $0) }
                    )
                    .focused($focusedKey, equals: item.key)
                    // UX-14 — F1's release notes live in the inspector only: unfolding them
                    // here gave every row a different height and repeated the inspector.
                }
                .opacity(run?.isDimmed(item.key) == true ? 0.55 : 1)
                .contextMenu {
                    if isEnabled {
                        UpdatePolicyMenu(onIgnore: { onIgnore?(item) }, onPin: { onPin?(item) }, onSkip: skipAction(for: item))
                    }
                }
                .overlay(alignment: .bottom) {
                    if item.id != items.last?.id { Divider().opacity(0.4).padding(.leading, 54) }
                }
            }
        }
        .focusSection()
        .onChange(of: focusedKey) { _, key in if let key { focus(key) } }
    }

    private func move(from key: String, in keys: [String], _ direction: RowMoveDirection) -> Bool {
        guard let next = UpdateRowFocus.neighbour(of: key, in: keys, direction: direction) else { return false }
        focus(next)
        return true
    }

    /// Makes `key` the group's Tab stop and focuses it — by arrow, by click, or when Tab arrives.
    private func focus(_ key: String) {
        tabStop = key
        focusedKey = key
    }

    private func toggle(_ key: String) {
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }

    /// Ticks the whole section, or clears it when it is already fully ticked. Sections the
    /// user picked rows in are left exactly as they were.
    private func toggleGroup() {
        selected = UpdatePlanner.toggledGroup(selected: selected, groupKeys: items.map(\.key))
    }
}

/// Shared context-menu content for ignoring, skipping, or pinning an update.
private struct UpdatePolicyMenu: View {
    let onIgnore: () -> Void
    let onPin:    () -> Void
    /// UX-12 — nil when there is no concrete version to skip, so the item is hidden.
    var onSkip:   (() -> Void)? = nil

    var body: some View {
        Button(action: onIgnore) {
            Label(tr("Nie aktualizuj"), systemImage: "bell.slash")
        }
        if let onSkip {
            Button(action: onSkip) {
                Label(tr("Pomiń tę wersję"), systemImage: "forward.end")
            }
        }
        Button(action: onPin) {
            Label(tr("Przypnij wersję…"), systemImage: "pin")
        }
    }
}

struct PinRequest: Identifiable {
    let key:              String
    let name:             String
    let suggestedVersion: String
    var id: String { key }
}

struct PinVersionSheet: View {
    let request:   PinRequest
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var version: String

    init(request: PinRequest, onConfirm: @escaping (String) -> Void) {
        self.request = request
        self.onConfirm = onConfirm
        _version = State(initialValue: request.suggestedVersion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Przypnij wersję")).font(.wega(.title3, weight: .bold))
                Text(request.name).font(.wega(.body)).foregroundStyle(.secondary)
            }

            Text(tr("Wega nie pokaże aktualizacji nowszych niż podana wersja. Zostaw bieżącą, żeby zatrzymać aplikację tu, gdzie jest."))
                .font(.wega(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(tr("Wersja"), text: $version)
                .textFieldStyle(.roundedBorder)
                .font(.wega(.body, monospaced: true))

            HStack {
                Spacer()
                Button(tr("Anuluj")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Przypnij")) {
                    onConfirm(version)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.wegaHoneyFill)
                .foregroundStyle(Color.wegaInk)
                .disabled(version.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

/// LT-01 — the updates the user can still take back: every committed upgrade whose
/// pre-upgrade snapshot is inside the retention window, newest first. This is the row the
/// whole journal exists for: "nowa wersja psuje mój workflow" gets a button, not a
/// support ticket.
struct UndoUpdateSection: View {
    let items: [UndoableUpdate]
    let busyToken: String?
    let onUndo: (UndoableUpdate) -> Void

    var body: some View {
        WegaCard {
            WegaCardHeader(
                icon: "arrow.uturn.backward.circle",
                title: tr("Cofnij aktualizację"),
                count: items.count,
                caption: tr("Kopie sprzed aktualizacji są trzymane przez 7 dni — w tym czasie możesz wrócić do poprzedniej wersji. Wega przypnie przywróconą wersję, żeby nie proponować jej od razu ponownie.")
            )
            ForEach(items) { item in
                HStack(spacing: 12) {
                    AppIcon(path: URL(fileURLWithPath: item.appPath), size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(CaskDisplayName.name(token: item.token, appPath: URL(fileURLWithPath: item.appPath)))
                            .fontWeight(.medium)
                        if item.token != CaskDisplayName.name(token: item.token, appPath: URL(fileURLWithPath: item.appPath)) {
                            Text(item.token)
                                .font(.wega(.caption, monospaced: true))
                                .foregroundStyle(.secondary)
                        }
                        Text(subtitle(for: item))
                            .font(.wega(.subheadline))
                            .foregroundStyle(.tertiary)
                        RollbackScopeNotice(scope: item.rollbackScope, compact: true)
                    }
                    Spacer()
                    if busyToken == item.token {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(tr("Cofnij")) { onUndo(item) }
                            .disabled(busyToken != nil)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    if item.id != items.last?.id { Divider().opacity(0.4).padding(.leading, 54) }
                }
            }
        }
        .padding(.top, 12)
    }

    private func subtitle(for item: UndoableUpdate) -> String {
        let restored = item.restoredVersion.map { trf("przywróci wersję %@", "\($0)") }
            ?? tr("przywróci poprzednią wersję")
        return trf("%@ · zaktualizowano %@ · kopia do %@",
                   restored,
                   item.updatedAt.formatted(date: .abbreviated, time: .shortened),
                   item.expiresAt.formatted(date: .abbreviated, time: .omitted))
    }
}

struct ManualUpdateSection: View {
    let items:     [ManualOutdatedApp]
    let busyToken: String?
    let onInstall: (String) -> Void
    let title:     String
    let tint:      Color
    /// UX-18 — the group's number, set only in urgency grouping.
    var ordinal:   Int? = nil
    var subtitle:  String? = nil
    /// Optional one-line explanation under the header — used to say *why* a brew-cask
    /// group sits apart (Homebrew doesn't version-manage `auto_updates` casks), so the
    /// section reads as intentional rather than an inconsistency.
    var caption:   String? = nil
    var inspectedKey: String? = nil
    var onIgnore:  ((ManualOutdatedApp) -> Void)?
    var onPin:     ((ManualOutdatedApp) -> Void)?
    var onSkip:    ((ManualOutdatedApp) -> Void)? = nil
    var onInspect: ((ManualOutdatedApp) -> Void)? = nil

    @FocusState private var focusedKey: String?
    @EnvironmentObject private var scan: ScanStore
    @Environment(\.updatesOnScreen) private var onScreen
    /// See `UpdateSection.isEnabled`.
    @Environment(\.isEnabled) private var isEnabled
    /// C2 §4.6 — the header labels groups made up entirely of hand-offs.
    @Environment(\.updateRun) private var run
    /// UXP-21 — the row Tab lands on; see `UpdateSection.tabStop`.
    @State private var tabStop: String?

    /// A skip closure only when the source reported a concrete version to skip.
    private func skipAction(for app: ManualOutdatedApp) -> (() -> Void)? {
        guard let onSkip, let version = app.availableVersion, !version.isEmpty else { return nil }
        return { onSkip(app) }
    }

    var body: some View {
        WegaCard {
            let keys = items.map(QueuedCaskReplacement.key(for:))
            let queueableKeys = Set(scan.queueableCaskReplacements(for: .all).map(\.key))
            UpdateGroupHeader(title: title, tint: tint, ordinal: ordinal, count: items.count,
                              note: run != nil && queueableKeys.isDisjoint(with: keys) ? tr("u producenta") : subtitle, caption: caption)

            ForEach(items, id: \.path) { item in
                let key = QueuedCaskReplacement.key(for: item)
                let isInspected = key == inspectedKey
                let isQueueable = queueableKeys.contains(key)
                let isQueued = scan.selected.contains(key)
                let runStatus = isQueueable ? run?.board.rows[key] : nil
                VStack(spacing: 0) {
                // UX-14 — the same columns as a package row: the hand-off mark holds the
                // queue column, so this icon lines up with every selectable row's, and the
                // version in the version column rather than under the name. F1's release notes
                // are in the inspector.
                HStack(spacing: WegaLayout.checkboxSpacing) {
                    if isQueueable {
                        Toggle(isOn: selectionToggleBinding(isOn: isQueued) {
                            scan.toggleQueuedCaskReplacement(item)
                        }) {
                            EmptyView()
                        }
                        .toggleStyle(WegaQueueToggleStyle())
                        .accessibilityLabel(trf("Kolejka: %@", item.name))
                        .focusable(false)
                        .disabled(run != nil)
                    } else {
                        QueueHandoffMark()
                    }
                    AppIcon(path: item.path, size: WegaLayout.updateIconSize)
                    let isSecurity = item.releaseNotes.map { ReleaseNotesTriage.heuristic($0.plainText).isLikelySecurityFix } ?? false
                    UpdateRowColumns {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.wega(.body, weight: .semibold))
                            Text((item.path.path as NSString).abbreviatingWithTildeInPath)
                                .font(.wega(.footnote))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: WegaLayout.rowDetailMaxWidth, alignment: .leading)
                                .help(item.path.path)
                            // FEAT-06: doradczy badge z triage notatek wydania (np. GitHub).
                            if isSecurity {
                                Label(tr("możliwa poprawka bezpieczeństwa"), systemImage: "shield.lefthalf.filled")
                                    .font(.wega(.footnote, weight: .medium))
                                    .foregroundStyle(Color.wegaDanger)
                            }
                        }
                    } version: {
                        if let runStatus {
                            UpdateRunStatusChip(status: runStatus, isStopping: run?.isStopping == true)
                                .accessibilityHidden(true)
                        } else {
                            VersionArrow(
                                from: item.installedVersion ?? "—",
                                to: item.availableVersion ?? "—",
                                emphasis: versionEmphasis(
                                    changeKind: versionChangeKind(from: item.installedVersion ?? "", to: item.availableVersion ?? ""),
                                    isSecurityFix: isSecurity, requiresForce: false
                                )
                            )
                        }
                    }
                    ManualUpdateActionView(item: item, busyToken: busyToken, onInstall: onInstall,
                                           isQueueableInList: isQueueable)
                }
                .padding(.horizontal, WegaLayout.cardPadding)
                .padding(.vertical, WegaLayout.updateRowPadding)
                }
                .queueRowSelection(isInspected)
                .opacity(run?.isDimmed(key) == true ? 0.55 : 1)
                .contentShape(Rectangle())
                .gesture(TapGesture().onEnded { focus(key); onInspect?(item) })
                .focusable(onInspect != nil && UpdateRowFocus.isTabStop(key, in: keys, focused: tabStop, onScreen: onScreen && isEnabled))
                .focused($focusedKey, equals: key)
                .onKeyPress(.return) {
                    guard isEnabled else { return .ignored }
                    return ManualUpdateRowKeyboardBehavior.handle(
                        .returnKey,
                        item: item,
                        onInspect: onInspect
                    ) ? .handled : .ignored
                }
                .onKeyPress(.space) {
                    guard isEnabled else { return .ignored }
                    if isQueueable, run == nil {
                        scan.toggleQueuedCaskReplacement(item)
                        return .handled
                    }
                    return ManualUpdateRowKeyboardBehavior.handle(
                        .spaceKey,
                        item: item,
                        onInspect: onInspect
                    ) ? .handled : .ignored
                }
                .onKeyPress(.upArrow) { move(from: key, in: keys, .up) ? .handled : .ignored }
                .onKeyPress(.downArrow) { move(from: key, in: keys, .down) ? .handled : .ignored }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(item.name)
                .accessibilityValue(
                    "\(item.installedVersion ?? "—") → \(item.availableVersion ?? "—")"
                )
                .accessibilityHint(isQueueable
                    ? tr("Naciśnij Return, aby pokazać szczegóły, lub spację, aby zmienić kolejkę.")
                    : tr("Naciśnij Return lub spację, aby pokazać szczegóły."))
                .accessibilityAction(named: tr("Pokaż szczegóły")) {
                    onInspect?(item)
                }
                .contextMenu {
                    if isEnabled {
                        UpdatePolicyMenu(onIgnore: { onIgnore?(item) }, onPin: { onPin?(item) }, onSkip: skipAction(for: item))
                    }
                }
                .overlay(alignment: .bottom) {
                    if item.path != items.last?.path { Divider().opacity(0.4).padding(.leading, 54) }
                }
            }
        }
        .focusSection()
        .onChange(of: focusedKey) { _, key in if let key { focus(key) } }
    }

    private func move(from key: String, in keys: [String], _ direction: RowMoveDirection) -> Bool {
        guard let next = UpdateRowFocus.neighbour(of: key, in: keys, direction: direction) else { return false }
        focus(next)
        return true
    }

    /// Makes `key` the group's Tab stop and focuses it — by arrow, by click, or when Tab arrives.
    private func focus(_ key: String) {
        tabStop = key
        focusedKey = key
    }
}

/// The per-source manual-update action control (badge + button/text), shared between
/// the list row (`ManualUpdateSection`) and the inspector pane so both render the
/// identical control for a given `ManualOutdatedApp.UpdateSource`.
///
/// ARCH-06 — the former 15-case, ~200-line `switch item.source` is gone. Each source now
/// carries its action as data (`UpdateSource.updateActionKind` / `.badgeLabel`, in Core);
/// this view renders the small, fixed vocabulary of `UpdateActionKind`s. The nine
/// self-updating vendors that were nine identical cases collapse into the one `.launchApp`
/// branch, so a new self-updating vendor needs no change here at all.
struct ManualUpdateActionView: View {
    let item:      ManualOutdatedApp
    let busyToken: String?
    let onInstall: (String) -> Void
    var isQueueableInList: Bool? = nil

    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var scan: ScanStore
    @ObservedObject private var upgrades = UpgradeCoordinator.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                WegaBadge(label: item.source.badgeLabel, color: item.source.provenance.badgeColor, role: .source)
                // REL-07: the Brew action retries a prior auto-rollback with a force-reinstall.
                if item.rolledBack {
                    WegaBadge(label: tr("cofnięto — ponów próbę"), variant: .danger)
                }
                trustPublisherControl
                if DockerDesktopUpdatePolicy.isDocker(item) {
                    DockerDesktopUpdateActions(item: item, busyToken: busyToken, onInstall: onInstall)
                } else if let profile = ServiceVendorUpdatePolicy.profile(for: item) {
                    ServiceVendorUpdateControls(profile: profile, appURL: item.path) {
                        scan.vendorOpened(item, succeeded: $0)
                    }
                    .frame(maxWidth: 340, alignment: .leading)
                } else {
                    actionControl
                }
            }
            .disabled(item.source.supportsVendorCompletion && (!scan.allowsVendorCheck || upgrades.state != .idle))
            if item.source.supportsVendorCompletion {
                VendorUpdateCompletionControls(item: item)
            }
        }
    }

    private func openVendor(_ url: URL?) {
        scan.vendorOpened(item, succeeded: url.map { NSWorkspace.shared.open($0) } ?? false)
    }

    /// A cask the watchdog rolled back over a publisher change can only move on once the user
    /// accepts the new Team ID — retrying the Brew action alone would be refused every time.
    @ViewBuilder
    private var trustPublisherControl: some View {
        if item.rolledBack, case .cask(let token) = item.source,
           scan.dependencies.rollbackLedger.reason(forToken: token) == .publisherChanged {
            Button {
                Task { await scan.trustNewPublisher(token: token, reportedTeamID: nil) }
            } label: {
                Label(tr("Zaufaj nowemu podpisowi"), systemImage: "checkmark.shield")
            }
            .controlSize(.small)
            .disabled(busyToken != nil)
        }
    }

    @ViewBuilder
    private var actionControl: some View {
        switch item.source.updateActionKind {
        case .launchApp:
            // Every self-updating vendor (Sparkle, ChatGPT, Discord, Chrome, Signal, …)
            // owns its own update flow: launching the app triggers the in-app updater. We
            // must never route these through `brew install` — their casks are
            // `auto_updates`/frozen and lag, so brew would reinstall a stale build.
            // UX-05: the button names its real effect — it opens the app (the vendor's own
            // updater then applies the staged build) — instead of promising an install Wega
            // does not perform.
            Button {
                openVendor(item.path)
            } label: {
                Label(tr("Otwórz aplikację"), systemImage: "arrow.up.forward.app")
            }
            .controlSize(.small)
        case .launchAppWithReleases(let releasesURL):
            // Akcja główna jest ta sama co w `.launchApp` — updater apki. Strona wydań
            // zostaje obok jako wyjście awaryjne, kontrolką wyraźnie drugorzędną, żeby
            // hierarchia była czytelna na pierwszy rzut oka.
            Button {
                openVendor(item.path)
            } label: {
                Label(tr("Otwórz aplikację"), systemImage: "arrow.up.forward.app")
            }
            .controlSize(.small)
            if let releasesURL {
                Button {
                    openVendor(releasesURL)
                } label: {
                    Text(tr("GitHub Releases"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.wegaHoney)
                .controlSize(.small)
            }
        case .brewInstall(let token):
            let isQueueable = isQueueableInList ?? scan.queueableCaskReplacements(for: .all).contains { $0.app == item }
            if isQueueable {
                if isQueueableInList == nil {
                    Button {
                        scan.toggleQueuedCaskReplacement(item)
                    } label: {
                        let queued = scan.selected.contains(QueuedCaskReplacement.key(for: item))
                        Label(queued ? tr("Usuń z kolejki") : tr("Dodaj do kolejki"),
                              systemImage: queued ? "minus.circle" : "plus.circle")
                    }
                    .controlSize(.small)
                    .disabled(scan.updating || scan.isRefreshing)
                }
            } else {
                Button {
                    onInstall(token)
                } label: {
                    if busyToken == token {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(tr("Aktualizuj przez Brew"), systemImage: "arrow.down.circle")
                    }
                }
                .controlSize(.small)
                .disabled(busyToken != nil || scan.updating || scan.isRefreshing)
            }
        case .appStore:
            Text(tr("zaktualizuj w App Store"))
                .font(.wega(.subheadline))
                .foregroundStyle(.tertiary)
        case .openURL(let url, let style):
            Button {
                openVendor(url)
            } label: {
                switch style {
                case .githubReleases:
                    // GitHub Releases is a page name, not an install promise — the external-link
                    // icon already reads as "opens a page", so it stays as-is.
                    Label(tr("GitHub Releases"), systemImage: "arrow.up.right.square")
                case .synologyDownload, .vendorDownload:
                    // UX-05: these merely open the vendor's download page — the button says so,
                    // rather than "Pobierz…", which suggested Wega performs the download/install.
                    Label(tr("Otwórz stronę pobierania"), systemImage: "arrow.up.right.square")
                }
            }
            .controlSize(.small)
        case .jetBrainsToolbox:
            Button {
                let toolboxPaths = [
                    SystemPaths.applicationsDirectory.appendingPathComponent("JetBrains Toolbox.app").path,
                    FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Applications/JetBrains Toolbox.app").path
                ]
                if let path = toolboxPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                    openVendor(URL(fileURLWithPath: path))
                } else {
                    openVendor(nil)
                }
            } label: {
                Label(tr("Otwórz Toolbox"), systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
        case .creativeCloud(let fallbackURL):
            Button {
                // LaunchServices, not a path: Creative Cloud installs outside /Applications
                // (`/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app`), so a
                // candidate-path list would miss it on the machines that have it. The web page
                // is only what is left when Adobe's client is genuinely not installed.
                let installed = CreativeCloudApplication.resolve {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
                }
                if let installed {
                    openVendor(installed)
                } else if let fallbackURL {
                    openVendor(fallbackURL)
                } else {
                    openVendor(nil)
                }
            } label: {
                Label(tr("Otwórz Creative Cloud"), systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
        case .microsoftAutoUpdate:
            MicrosoftAutoUpdateControls(app: ApplicationInfo(path: item.path, name: item.name,
                bundleIdentifier: item.bundleIdentifier, version: item.installedVersion, installDate: nil, updateDate: nil,
                isManagedByBrew: item.origin == .brew, isManagedByMas: item.origin == .appStore), item: item)
        case .openSelfUpdate:
            // The row leads to the in-app installer in Settings — signature verification,
            // the headless helper install and the restart all live there. Never a browser.
            Button {
                SettingsRoute.shared.open(.selfUpdate, with: openSettings)
            } label: {
                Label(tr("Aktualizuj Wegę"), systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
        }
    }
}

/// F1 — expands a row into the vendor's own release notes, one entry per release published
/// between the installed version and the one on offer.
///
/// The bodies arrived plain: `ReleaseNotes` is sanitised in Core, at the source that produced
/// it, so nothing here ever holds vendor HTML. Long histories are truncated in place with a
/// scroll rather than pushing the update list off screen.
///
/// A feed that publishes only a link (`ReleaseNotes.link`, no inline history) is fetched here,
/// once, the first time the row is expanded — never during a scan (`ReleaseNotesLoader`).
struct ReleaseNotesDisclosure: View {
    let notes: ReleaseNotes

    @State private var expanded = false
    @StateObject private var loader = ReleaseNotesLoader()

    init(notes: ReleaseNotes, expanded: Bool = false) {
        self.notes = notes
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        WegaDisclosure(isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Guarded, not merely empty-looping: a link-only value has no entries
                    // and no omitted count, and without this the disclosure would render an
                    // empty stack the user expands to nothing.
                    if notes.hasRenderableNotes {
                        ForEach(notes.history.notes) { note in
                            ReleaseNoteView(note: note, bodyFont: .wega(.subheadline))
                        }
                        if notes.history.omitted > 0 {
                            Text(trp("…i %@ wcześniejszych wydań", notes.history.omitted))
                                .font(.wega(.subheadline))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    linkedNotes
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 160)
        } label: {
            Text(tr("Co nowego"))
                .font(.wega(.subheadline, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        // The fetch belongs to the expansion, not to the scan: a row nobody opens costs
        // nothing. `.task(id:)` re-runs on collapse too, which `loadIfNeeded` absorbs.
        .task(id: expanded) {
            guard expanded else { return }
            await loader.loadIfNeeded(from: notes.link)
        }
    }

    /// The branch for a feed that published a link instead of a body.
    @ViewBuilder
    private var linkedNotes: some View {
        switch loader.state {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("Pobieram notatki wydania…"))
                    .font(.wega(.subheadline))
                    .foregroundStyle(.tertiary)
            }
        case .loaded(let text, let truncated):
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.wega(.subheadline))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if truncated, let link = notes.link {
                    HStack(spacing: 6) {
                        Text(tr("Notatki są dłuższe — to początek"))
                            .font(.wega(.footnote))
                            .foregroundStyle(.tertiary)
                        Link(tr("Zobacz pełne notatki"), destination: link)
                            .font(.wega(.footnote))
                    }
                }
            }
        case .failed:
            HStack(spacing: 6) {
                Text(tr("Nie udało się pobrać notatek wydania"))
                    .font(.wega(.subheadline))
                    .foregroundStyle(.tertiary)
                Button(tr("Spróbuj ponownie")) {
                    Task { await loader.retry(from: notes.link) }
                }
                .controlSize(.small)
                if let link = notes.link {
                    Link(tr("Zobacz u producenta"), destination: link).font(.wega(.subheadline))
                }
            }
        }
    }
}
