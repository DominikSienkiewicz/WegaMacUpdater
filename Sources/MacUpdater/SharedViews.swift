import SwiftUI
import MacUpdaterCore

// MARK: - Shared scan-directory helper

/// /Applications, ~/Applications, and their immediate non-.app subdirectories.
/// Implementation lives in `MacUpdaterCore.AppScanDirectories` so the menu-bar agent
/// shares it.
func buildScanDirs() -> [URL] {
    AppScanDirectories.all()
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 20)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 6)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - WegaBadge

enum WegaBadgeVariant {
    case brew, appStore, manual, success, danger, info

    var bg: Color {
        switch self {
        case .brew:     return Color.wegaHoney.opacity(0.12)
        case .appStore: return Color.wegaInfo.opacity(0.12)
        case .manual:   return Color.wegaDanger.opacity(0.10)
        case .success:  return Color.wegaSuccess.opacity(0.12)
        case .danger:   return Color.wegaDanger.opacity(0.12)
        case .info:     return Color.wegaInfo.opacity(0.12)
        }
    }
    var fg: Color {
        switch self {
        case .brew:     return .wegaHoney
        case .appStore: return .wegaInfo
        case .manual:   return .wegaDanger
        case .success:  return .wegaSuccess
        case .danger:   return .wegaDanger
        case .info:     return .wegaInfo
        }
    }
}

struct WegaBadge: View {
    let label: String
    var variant: WegaBadgeVariant = .brew
    private var explicitColor: Color?

    init(label: String, variant: WegaBadgeVariant = .brew) {
        self.label = label
        self.variant = variant
        self.explicitColor = nil
    }

    /// Renders with an explicit colour instead of a `WegaBadgeVariant` — same
    /// layout/metrics as the variant initializer, used for provenance-based
    /// colour-coding where the colour isn't one of the fixed variants.
    init(label: String, color: Color) {
        self.label = label
        self.variant = .brew
        self.explicitColor = color
    }

    private var fg: Color { explicitColor ?? variant.fg }
    private var bg: Color { explicitColor?.opacity(0.12) ?? variant.bg }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(fg.opacity(0.25), lineWidth: 1))
    }
}

extension Provenance {
    /// Badge colour per provenance family, from Wega's existing palette.
    var badgeColor: Color {
        switch self {
        case .homebrew:     return .wegaHoney
        case .appStore:     return .wegaInfo
        case .vendorDirect: return .wegaSuccess
        case .github:       return .wegaLavender
        case .jetbrains:    return .wegaCoral
        case .sparkle:      return .wegaLavender
        case .synology:     return .wegaInfo
        }
    }
}

// MARK: - WegaCard

struct WegaCard<Content: View>: View {
    var padded: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: WegaLayout.cardRadius))
    }
}

// MARK: - AppIcon

struct AppIcon: View {
    let path: URL
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path.path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

// MARK: - PackageLetterIcon

struct PackageLetterIcon: View {
    let name: String
    var size: CGFloat = 28

    private var letter: String { String(name.first ?? "?").uppercased() }
    private var bg: Color {
        let h = name.unicodeScalars.reduce(0) { $0 + $1.value } % 4
        let hues: [Double] = [0.08, 0.12, 0.06, 0.10]
        return Color(hue: hues[Int(h)], saturation: 0.6, brightness: 0.65)
    }

    var body: some View {
        Text(letter)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: size, height: size)
            .background(bg, in: RoundedRectangle(cornerRadius: size * 0.22))
    }
}

// MARK: - VersionArrow

extension VersionEmphasisKind {
    /// Maps semantic emphasis to a Wega palette colour. Normal = honey, major =
    /// caramel, security = danger red, forced (brew --force) = toffee.
    var versionColor: Color {
        switch self {
        case .normal:   return .wegaHoney
        case .major:    return .wegaCaramel
        case .security: return .wegaDanger
        case .forced:   return .wegaToffee
        }
    }
}

struct VersionArrow: View {
    let from: String
    let to: String
    var emphasis: VersionEmphasisKind = .normal

    var body: some View {
        HStack(spacing: 5) {
            Text(from).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary).font(.system(size: 9))
            Text(to).foregroundStyle(emphasis.versionColor)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

// MARK: - PackageRow

struct PackageRow: View {
    let name: String
    var token: String?          = nil
    var iconPath: URL?          = nil
    var currentVersion: String? = nil
    var latestVersion: String?  = nil
    var isSelected: Bool        = false
    var isInspected: Bool       = false
    var securityFix: Bool       = false
    var requiresForce: Bool     = false
    /// M5 — whether snapshot → canary → auto-rollback covers this upgrade. `nil` where the
    /// question does not apply (formulae, npm, App Store), so the row stays silent rather
    /// than implying a verdict it does not have.
    var rollback: RollbackProtection.Verdict? = nil
    var onToggle: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil
    /// M5 — the ignore / pin actions, previously reachable only by right-click.
    var onIgnore: (() -> Void)? = nil
    var onPin:    (() -> Void)? = nil
    /// F3 — per-app opt-in for unattended background upgrades. Offered only where the
    /// rollback net covers the cask, so the menu never proposes what Wega cannot undo.
    var backgroundUpdateToken: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            if onToggle != nil {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.wegaHoney : .secondary)
                    .font(.system(size: 16))
                    .onTapGesture { onToggle?() }
            }
            if let path = iconPath {
                AppIcon(path: path, size: 28)
            } else {
                PackageLetterIcon(name: name)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium))
                if let t = token {
                    Text(t)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let rollback { RollbackBadge(verdict: rollback) }
            if let from = currentVersion, let to = latestVersion {
                let kind = versionChangeKind(from: from, to: to)
                let emphasis = versionEmphasis(changeKind: kind,
                                               isSecurityFix: securityFix,
                                               requiresForce: requiresForce)
                VersionArrow(from: from, to: to, emphasis: emphasis)
            } else if let v = currentVersion ?? latestVersion {
                Text(v)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if onIgnore != nil || onPin != nil {
                Menu {
                    if let onIgnore {
                        Button(action: onIgnore) { Label(tr("Nie aktualizuj"), systemImage: "bell.slash") }
                    }
                    if let onPin {
                        Button(action: onPin) { Label(tr("Przypnij wersję…"), systemImage: "pin") }
                    }
                    if let token = backgroundUpdateToken, rollback == .protected {
                        Divider()
                        BackgroundUpdateToggle(token: token)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .accessibilityLabel(tr("Więcej działań"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isSelected ? Color.wegaHoney.opacity(0.05) : Color.clear)
        .background(isInspected ? Color.wegaHoney.opacity(0.14) : Color.clear)
        .overlay(alignment: .leading) {
            if isInspected {
                Rectangle().fill(Color.wegaHoney).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
    }
}

// MARK: - Rollback badge (M5)

/// Surfaces the snapshot → canary → auto-rollback net that has always run and never showed.
///
/// It deliberately promises only what happens *during* this upgrade: if the new version
/// fails its Gatekeeper check, the previous one comes back automatically. It does not offer
/// a manual "Undo" — the snapshot lives only for the canary window and is deleted right
/// after, so a button implying otherwise would be a lie.
private struct RollbackBadge: View {
    let verdict: RollbackProtection.Verdict

    var body: some View {
        switch verdict {
        case .protected:
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 12))
                .foregroundStyle(Color.wegaSuccess)
                .help(tr("Przed aktualizacją robię kopię. Jeśli nowa wersja nie przejdzie testu, wracam do poprzedniej."))
                .accessibilityLabel(tr("Chronione automatycznym cofnięciem"))
        case .unprotected:
            Image(systemName: "shield.slash")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .help(tr("Ten cask nie instaluje aplikacji, więc nie da się zrobić kopii ani cofnąć aktualizacji."))
                .accessibilityLabel(tr("Bez ochrony cofnięciem"))
        }
    }
}

// MARK: - EmptyHero

struct EmptyHero: View {
    var pose: WegaPose = .idle
    var title: String
    var message: String
    var action: AnyView? = nil
    var compact: Bool    = false
    /// When true, Wega idles and pulls random tricks instead of standing still.
    var playful: Bool    = false

    var body: some View {
        VStack(spacing: 16) {
            if playful {
                PlayfulWega(restPose: pose, size: compact ? 130 : 170)
            } else {
                WegaFull(pose: pose, size: compact ? 130 : 170, showBall: pose == .idle)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            if let action { action }
        }
        .padding(compact ? 32 : 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - BannerData + BannerView

enum BannerAction: Equatable { case openLogs, openSettings }

struct BannerData: Equatable {
    enum Variant { case success, danger }
    let variant: Variant
    let title: String
    let message: String
    var action: BannerAction? = nil
}

struct BannerView: View {
    let data: BannerData
    var onAction: ((BannerAction) -> Void)? = nil
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: data.variant == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(data.variant == .success ? Color.wegaSuccess : Color.wegaDanger)
            VStack(alignment: .leading, spacing: 2) {
                Text(data.title).font(.system(size: 13, weight: .semibold))
                Text(data.message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let action = data.action {
                let actionLabel: String = {
                    switch action {
                    case .openLogs:     return tr("Zobacz w logach")
                    case .openSettings: return tr("Włącz Touch ID")
                    }
                }()
                Button { onAction?(action) } label: {
                    Label(actionLabel, systemImage: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.wegaHoney)
                .accessibilityLabel(actionLabel)
            }
            Button { onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(tr("Zamknij"))
        }
        .padding(14)
        .background(
            data.variant == .success ? Color.wegaSuccess.opacity(0.08) : Color.wegaDanger.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    data.variant == .success ? Color.wegaSuccess.opacity(0.3) : Color.wegaDanger.opacity(0.3),
                    lineWidth: 1
                )
        )
    }
}

/// F3 — the per-app opt-in, in the row's ⋯ menu.
///
/// Offered only for casks the rollback net actually covers. Turning it on does not promise
/// that this app *will* update in the background: the eligibility predicate still has the
/// last word (no privileged hooks, a verified checksum, and the app not running), and
/// nothing runs at all while Wega is closed — it is a menu-bar agent, not a daemon.
private struct BackgroundUpdateToggle: View {
    let token: String

    @ObservedObject private var store = BackgroundUpdateOptInStore.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { store.isOptedIn(token) },
            set: { store.setOptedIn($0, token: token) }
        )) {
            Label(tr("Aktualizuj automatycznie w tle"), systemImage: "clock.arrow.2.circlepath")
        }
    }
}
