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
    var onInspect: ((OutdatedItem) -> Void)? = nil

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
                    onPin:          { onPin?(item) }
                )
                .contextMenu {
                    UpdatePolicyMenu(onIgnore: { onIgnore?(item) }, onPin: { onPin?(item) })
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

/// Shared context-menu content for ignoring or pinning an update.
private struct UpdatePolicyMenu: View {
    let onIgnore: () -> Void
    let onPin:    () -> Void

    var body: some View {
        Button(action: onIgnore) {
            Label(tr("Nie aktualizuj"), systemImage: "bell.slash")
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
                .foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.07))
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
    var onInspect: ((ManualOutdatedApp) -> Void)? = nil

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
                .background(isInspected ? Color.wegaHoney.opacity(0.14) : Color.clear)
                .overlay(alignment: .leading) {
                    if isInspected {
                        Rectangle().fill(Color.wegaHoney).frame(width: 2)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onInspect?(item) }
                .contextMenu {
                    UpdatePolicyMenu(onIgnore: { onIgnore?(item) }, onPin: { onPin?(item) })
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
/// identical control for a given `ManualOutdatedApp.UpdateSource` — extracted verbatim
/// from the former `ManualUpdateSection.manualAction(for:)` (I-3), no behavior change.
struct ManualUpdateActionView: View {
    let item:      ManualOutdatedApp
    let busyToken: String?
    let onInstall: (String) -> Void

    var body: some View {
        switch item.source {
        case .sparkle:
            HStack(spacing: 8) {
                WegaBadge(label: "Sparkle", color: item.source.provenance.badgeColor)
                Button {
                    // Sparkle apps own the update flow. Opening the app brings it to the
                    // foreground and (for apps with SUEnableAutomaticChecks=1, e.g. Codex)
                    // triggers the appcast check on launch — the user then accepts in the
                    // app's own update prompt. We can't drive that prompt from outside
                    // without an AppleScript that depends on each app's menu wording.
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
        case .cask(let token):
            HStack(spacing: 8) {
                WegaBadge(label: token, color: item.source.provenance.badgeColor)
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
            }
        case .mas(let appStoreID):
            HStack(spacing: 8) {
                WegaBadge(label: appStoreID, color: item.source.provenance.badgeColor)
                Text(tr("zaktualizuj w App Store"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        case .github(let repo):
            HStack(spacing: 8) {
                WegaBadge(label: "GitHub", color: item.source.provenance.badgeColor)
                Button {
                    if let url = AppEndpoints.shared.githubReleasesPageURL(repo: repo) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(tr("GitHub Releases"), systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
        case .jetbrains(let caskToken):
            HStack(spacing: 8) {
                WegaBadge(label: caskToken, color: item.source.provenance.badgeColor)
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
        case .synology(let downloadPage):
            HStack(spacing: 8) {
                WegaBadge(label: "Synology", color: item.source.provenance.badgeColor)
                Button {
                    if let url = URL(string: downloadPage) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(tr("Pobierz ze strony Synology"), systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
        case .antigravity:
            HStack(spacing: 8) {
                WegaBadge(label: "Antigravity", color: item.source.provenance.badgeColor)
                Button {
                    // Antigravity owns its own update flow (supportsFastUpdate).
                    // Launching it triggers the in-app updater — we must never
                    // route this through `brew install`, because the Homebrew
                    // cask is frozen at an older version and would downgrade it.
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
        case .parallels:
            HStack(spacing: 8) {
                WegaBadge(label: "Parallels", color: item.source.provenance.badgeColor)
                Button {
                    // Parallels self-updates via its bundled updater; brew cask
                    // `parallels` lags upstream and would route through a stale
                    // installer.
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
        case .googleDrive:
            HStack(spacing: 8) {
                WegaBadge(label: "Google Drive", color: item.source.provenance.badgeColor)
                Button {
                    NSWorkspace.shared.open(AppEndpoints.shared.googleDriveDownloadURL)
                } label: {
                    Label(tr("Pobierz najnowszą wersję"), systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
        case .chatgpt:
            HStack(spacing: 8) {
                WegaBadge(label: "ChatGPT", color: item.source.provenance.badgeColor)
                Button {
                    // ChatGPT self-updates via Sparkle from a runtime-resolved
                    // feed; the brew cask `chatgpt` is `auto_updates` and lags.
                    // Launching the app triggers its own update flow — never
                    // route through brew, which would reinstall a stale build.
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
        case .postman:
            HStack(spacing: 8) {
                WegaBadge(label: "Postman", color: item.source.provenance.badgeColor)
                Button {
                    // Postman self-updates via Squirrel; the brew cask `postman`
                    // is `auto_updates` and its version lags the real channel, so
                    // `brew install --cask postman` would (re)install the STALE
                    // build. Launch the app and let its own updater pull the build
                    // the Squirrel feed reported.
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
        case .discord:
            HStack(spacing: 8) {
                WegaBadge(label: "Discord", color: item.source.provenance.badgeColor)
                Button {
                    // Discord self-updates its host via Squirrel; the discord* casks are
                    // auto_updates and lag, so brew would reinstall a stale build.
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
        case .signal:
            HStack(spacing: 8) {
                WegaBadge(label: "Signal", color: item.source.provenance.badgeColor)
                Button {
                    // Signal self-updates via electron-updater; the signal cask is
                    // auto_updates and lags. Launch it so its own updater applies.
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
        case .chrome:
            HStack(spacing: 8) {
                WegaBadge(label: "Chrome", color: item.source.provenance.badgeColor)
                Button {
                    // Chrome self-updates via Keystone; the google-chrome* casks are
                    // auto_updates and lag. Relaunch applies the staged update.
                    NSWorkspace.shared.open(item.path)
                } label: {
                    Label(tr("Otwórz i zaktualizuj"), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
        }
    }
}
