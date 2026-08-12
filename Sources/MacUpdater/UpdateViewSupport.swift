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
    }
}

/// The upgrade's progress, in whole packages finished out of the batch the run planned.
///
/// There is no percentage to show: piped brew runs curl with `--silent`, so the bytes are
/// invisible from here (see `INSTALL_PROGRESS_DESIGN.md`). What the bar reports is finished
/// work — the rule the scan's bar already follows — and the line under it names the phase,
/// plus the package whenever the run can honestly name one: brew announces its own, npm's
/// loop already knows it, and the App Store's one opaque call names nothing.
struct UpgradeProgressBar: View {
    let progress: UpgradeProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar
                .tint(Color.wegaHoney)
                // A linear ProgressView reports a nonzero intrinsic width, which — with no
                // upper bound — propagates up and pushes the detail column wide enough to
                // shove the sidebar off-screen. Pin it elastic (0…∞) so it fills, not forces.
                .frame(minWidth: 0, maxWidth: .infinity)
            Text(label)
                .font(.wega(.subheadline, monospaced: true))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("Postęp aktualizacji"))
        // `label` already ends with the counter, so it is the whole sentence a sighted
        // user reads — the combined children would otherwise be replaced by a bare count.
        .accessibilityValue(label)
    }

    @ViewBuilder
    private var bar: some View {
        if progress.stage == .preparing {
            // Nothing has been counted yet, so the bar declines to claim a value.
            ProgressView().progressViewStyle(.linear)
        } else {
            ProgressView(value: progress.fractionCompleted).progressViewStyle(.linear)
        }
    }

    private var counter: String {
        trf("%@ z %@", "\(progress.completedUnits)", "\(progress.totalUnits)")
    }

    private var label: String {
        switch progress.stage {
        case .preparing:
            return tr("Przygotowuję kopie zapasowe…")
        case .downloading(let token?):
            return trf("Pobieram %@ — %@", "\(token)", "\(counter)")
        case .downloading:
            return trf("Pobieram pakiety — %@", "\(counter)")
        case .installing(let token?):
            return trf("Instaluję %@ — %@", "\(token)", "\(counter)")
        case .installing:
            return trf("Instaluję pakiety — %@", "\(counter)")
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
                    .font(.wega(.footnote, weight: .semibold, monospaced: true))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.wega(.caption, weight: .semibold))
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
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
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
    let subtitle:  String
    let icon:      String
    let items:     [OutdatedItem]
    var iconPaths: [String: URL]  = [:]
    /// M5 — rollback coverage per cask token. Empty for sections where the question does
    /// not apply (formulae, npm, App Store), which leaves the rows unbadged.
    var rollbackProtection: [String: RollbackProtection.Verdict] = [:]
    /// LT-01 — sources Wega cannot roll back say so under their header, instead of
    /// letting the cask shield imply a safety net the other sections do not have.
    var rollbackCaption: String? = nil
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
            WegaCardHeader(icon: icon, title: title, count: items.count, note: subtitle,
                           caption: rollbackCaption)

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
                        Text(item.token).fontWeight(.medium)
                        Text(subtitle(for: item))
                            .font(.wega(.subheadline))
                            .foregroundStyle(.tertiary)
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
            WegaCardHeader(icon: icon, title: title, count: items.count,
                           note: subtitle, caption: caption)

            ForEach(items, id: \.path) { item in
                let isInspected = "m:" + item.path.path == inspectedKey
                VStack(spacing: 0) {
                HStack(spacing: 12) {
                    AppIcon(path: item.path, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.wega(.body, weight: .medium))
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
                                .font(.wega(.footnote, weight: .medium))
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

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            WegaBadge(label: item.source.badgeLabel, color: item.source.provenance.badgeColor)
            // REL-07 — a cask a prior auto-rollback reverted is forced back onto the list with
            // this label so the user sees it is not current; the Brew action below is the retry
            // (a force-reinstall that repairs Homebrew's metadata on a healthy result).
            if item.rolledBack {
                WegaBadge(label: tr("cofnięto — ponów próbę"), variant: .danger)
            }
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
            // UX-05: the button names its real effect — it opens the app (the vendor's own
            // updater then applies the staged build) — instead of promising an install Wega
            // does not perform.
            Button {
                NSWorkspace.shared.open(item.path)
            } label: {
                Label(tr("Otwórz aplikację"), systemImage: "arrow.up.forward.app")
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
                .font(.wega(.subheadline))
                .foregroundStyle(.tertiary)
        case .openURL(let url, let style):
            Button {
                if let url { NSWorkspace.shared.open(url) }
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
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
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
                    NSWorkspace.shared.open(installed)
                } else if let fallbackURL {
                    NSWorkspace.shared.open(fallbackURL)
                }
            } label: {
                Label(tr("Otwórz Creative Cloud"), systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
        case .openSelfUpdate:
            // The row leads to the in-app installer in Settings — signature verification,
            // the headless helper install and the restart all live there. Never a browser.
            Button {
                openSettings()
            } label: {
                Label(tr("Aktualizuj Wegę"), systemImage: "arrow.down.circle")
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
            WegaDisclosure(isExpanded: $expanded) {
                ScrollView {
                    Text(text)
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .frame(maxHeight: 160)
            } label: {
                Text(tr("Co nowego"))
                    .font(.wega(.subheadline, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
