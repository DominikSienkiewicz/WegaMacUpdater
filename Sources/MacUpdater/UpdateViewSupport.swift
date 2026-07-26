import SwiftUI
import MacUpdaterCore

// Supporting views for `UpdateView`, split out to keep `UpdateView.swift` within
// SwiftLint's file_length budget. Module-internal (not `private`) so `UpdateView`
// in its own file can reference them.

struct RestartSection: View {
    let candidates:   [RestartInfo]
    let busyProcess:  String?
    let onRestart:    (RestartInfo) -> Void

    var body: some View {
        WegaCard {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle").foregroundStyle(Color.wegaHoney)
                Text(tr("Do restartu")).font(.system(size: 13, weight: .semibold))
                Text("\(candidates.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                Text(tr("były otwarte podczas aktualizacji")).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }

            ForEach(candidates, id: \.processName) { info in
                HStack(spacing: 12) {
                    PackageLetterIcon(name: info.appName, size: 32)
                    Text(info.appName).font(.system(size: 13, weight: .medium))
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
    }
}

struct BrewLogPanel: View {
    let lines:   [String]
    let onClose: () -> Void

    var body: some View {
        WegaCard(padded: false) {
            HStack(spacing: 8) {
                Circle().fill(Color.wegaSuccess).frame(width: 6, height: 6)
                Text("brew log")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Zamknij"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider().opacity(0.4) }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
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
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }
}

struct CheckingBar: View {
    let command: String
    let delay:   Double

    @State private var visible = false

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(Color.wegaHoney)
            Text("$ \(command)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.wegaHoney.opacity(0.15))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [Color.wegaToffee, Color.wegaHoney], startPoint: .leading, endPoint: .trailing))
                        .frame(width: visible ? .infinity : 0)
                        .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: visible)
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
    let subtitle:  String
    let icon:      String
    let items:     [OutdatedItem]
    var iconPaths: [String: URL]  = [:]
    /// M5 — rollback coverage per cask token. Empty for sections where the question does
    /// not apply (formulae, npm, App Store), which leaves the rows unbadged.
    var rollbackProtection: [String: RollbackProtection.Verdict] = [:]
    @Binding var selected: Set<String>
    var inspectedKey: String? = nil
    var onIgnore: ((OutdatedItem) -> Void)?
    var onPin:    ((OutdatedItem) -> Void)?
    var onSkip:   ((OutdatedItem) -> Void)? = nil
    var onInspect: ((OutdatedItem) -> Void)? = nil

    /// A skip closure only when there is a concrete version on offer to skip.
    private func skipAction(for item: OutdatedItem) -> (() -> Void)? {
        guard let onSkip, let to = item.to, !to.isEmpty else { return nil }
        return { onSkip(item) }
    }

    var body: some View {
        WegaCard {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Color.wegaHoney)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(items.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }

            ForEach(items) { item in
                PackageRow(
                    name:           item.name,
                    iconPath:       iconPaths[item.name],
                    currentVersion: item.from,
                    latestVersion:  item.to,
                    isSelected:     selected.contains(item.key),
                    isInspected:    item.key == inspectedKey,
                    rollback:       rollbackProtection[item.name],
                    onToggle:       { toggle(item.key) },
                    onSelect:       { onInspect?(item) },
                    onIgnore:       { onIgnore?(item) },
                    onPin:          { onPin?(item) },
                    onSkip:         skipAction(for: item),
                    backgroundUpdateToken: item.kind == .cask ? item.name : nil
                )
                .contextMenu {
                    UpdatePolicyMenu(onIgnore: { onIgnore?(item) }, onPin: { onPin?(item) }, onSkip: skipAction(for: item))
                }
                .overlay(alignment: .bottom) {
                    if item.id != items.last?.id { Divider().opacity(0.4).padding(.leading, 54) }
                }
            }
        }
    }

    private func toggle(_ key: String) {
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
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
                Text(tr("Przypnij wersję")).font(.system(size: 16, weight: .bold))
                Text(request.name).font(.system(size: 13)).foregroundStyle(.secondary)
            }

            Text(tr("Wega nie pokaże aktualizacji nowszych niż podana wersja. Zostaw bieżącą, żeby zatrzymać aplikację tu, gdzie jest."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(tr("Wersja"), text: $version)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))

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
                .tint(Color.wegaHoney)
                .foregroundStyle(Color.wegaInk)
                .disabled(version.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

struct ManualUpdateSection: View {
    let items:     [ManualOutdatedApp]
    let busyToken: String?
    let onInstall: (String) -> Void
    let title:     String
    let icon:      String
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

    /// A skip closure only when the source reported a concrete version to skip.
    private func skipAction(for app: ManualOutdatedApp) -> (() -> Void)? {
        guard let onSkip, let version = app.availableVersion, !version.isEmpty else { return nil }
        return { onSkip(app) }
    }

    var body: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(Color.wegaHoney)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(items.count)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }

            ForEach(items, id: \.path) { item in
                let isInspected = "m:" + item.path.path == inspectedKey
                VStack(spacing: 0) {
                HStack(spacing: 12) {
                    AppIcon(path: item.path, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 13, weight: .medium))
                        let isSecurity = item.releaseNotes.map { ReleaseNotesTriage.heuristic($0).isLikelySecurityFix } ?? false
                        VersionArrow(
                            from: item.installedVersion ?? "—",
                            to: item.availableVersion ?? "—",
                            emphasis: versionEmphasis(
                                changeKind: versionChangeKind(from: item.installedVersion ?? "", to: item.availableVersion ?? ""),
                                isSecurityFix: isSecurity,
                                // Self-updating rows never go through brew's --force retry, so requiresForce is always false here.
                                requiresForce: false
                            )
                        )
                        // FEAT-06: doradczy badge z triage notatek wydania (np. GitHub).
                        if isSecurity {
                            Label(tr("możliwa poprawka bezpieczeństwa"), systemImage: "shield.lefthalf.filled")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.wegaDanger)
                        }
                    }
                    Spacer()
                    ManualUpdateActionView(item: item, busyToken: busyToken, onInstall: onInstall)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                // F1 — the release notes, inline, from whichever source could supply them.
                // Rows whose source publishes none simply have no disclosure: the UI says
                // nothing rather than inventing a "no changes" that it cannot know.
                if let notes = item.releaseNotes, !notes.isEmpty {
                    ReleaseNotesDisclosure(notes: notes)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
                }
                .background(isInspected ? Color.wegaHoney.opacity(0.14) : Color.clear)
                .overlay(alignment: .leading) {
                    if isInspected {
                        Rectangle().fill(Color.wegaHoney).frame(width: 2)
                    }
                }
                .contentShape(Rectangle())
                .gesture(TapGesture().onEnded { onInspect?(item) })
                .focusable(onInspect != nil)
                .onKeyPress(.return) {
                    ManualUpdateRowKeyboardBehavior.handle(
                        .returnKey,
                        item: item,
                        onInspect: onInspect
                    ) ? .handled : .ignored
                }
                .onKeyPress(.space) {
                    ManualUpdateRowKeyboardBehavior.handle(
                        .spaceKey,
                        item: item,
                        onInspect: onInspect
                    ) ? .handled : .ignored
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(item.name)
                .accessibilityValue(
                    "\(item.installedVersion ?? "—") → \(item.availableVersion ?? "—")"
                )
                .accessibilityHint(tr("Naciśnij Return lub spację, aby pokazać szczegóły."))
                .accessibilityAction(named: tr("Pokaż szczegóły")) {
                    onInspect?(item)
                }
                .contextMenu {
                    UpdatePolicyMenu(onIgnore: { onIgnore?(item) }, onPin: { onPin?(item) }, onSkip: skipAction(for: item))
                }
                .overlay(alignment: .bottom) {
                    if item.path != items.last?.path { Divider().opacity(0.4).padding(.leading, 54) }
                }
            }
        }
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

    var body: some View {
        HStack(spacing: 8) {
            WegaBadge(label: item.source.badgeLabel, color: item.source.provenance.badgeColor)
            actionControl
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
            Button {
                NSWorkspace.shared.open(item.path)
            } label: {
                Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")
            }
            .controlSize(.small)
        case .brewInstall(let token):
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
            .disabled(busyToken != nil)
        case .appStore:
            Text(tr("zaktualizuj w App Store"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        case .openURL(let url, let style):
            Button {
                if let url { NSWorkspace.shared.open(url) }
            } label: {
                switch style {
                case .githubReleases:
                    Label(tr("GitHub Releases"), systemImage: "arrow.up.right.square")
                case .synologyDownload:
                    Label(tr("Pobierz ze strony Synology"), systemImage: "arrow.up.right.square")
                case .vendorDownload:
                    Label(tr("Pobierz najnowszą wersję"), systemImage: "arrow.up.right.square")
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
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            } label: {
                Label(tr("Otwórz Toolbox"), systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
        }
    }
}

/// F1 — expands a row into the vendor's own release notes.
///
/// The text is scrubbed of markup by `ReleaseNotesText` first: it arrives as HTML from a
/// Sparkle appcast or the JetBrains API, written by a third party and fetched over the
/// network, and Wega renders it. Long notes are truncated in place with a scroll rather
/// than pushing the update list off screen.
private struct ReleaseNotesDisclosure: View {
    let notes: String

    @State private var expanded = false

    private var text: String { ReleaseNotesText.plain(fromHTML: notes) }

    var body: some View {
        if !text.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .frame(maxHeight: 160)
            } label: {
                Text(tr("Co nowego"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
