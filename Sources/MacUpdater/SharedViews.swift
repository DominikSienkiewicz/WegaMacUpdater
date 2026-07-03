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

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(variant.fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(variant.bg, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(variant.fg.opacity(0.25), lineWidth: 1))
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
        .overlay(RoundedRectangle(cornerRadius: WegaLayout.cardRadius).stroke(Color.white.opacity(0.06), lineWidth: 1))
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
    var securityFix: Bool       = false
    var requiresForce: Bool     = false
    var onToggle: (() -> Void)? = nil

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isSelected ? Color.wegaHoney.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onToggle?() }
    }
}

// MARK: - EmptyHero

struct EmptyHero: View {
    var pose: WegaPose = .idle
    var title: String
    var message: String
    var action: AnyView? = nil
    var compact: Bool    = false

    var body: some View {
        VStack(spacing: 16) {
            WegaFull(pose: pose, size: compact ? 130 : 170, showBall: pose == .idle)
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

enum BannerAction: Equatable { case openLogs }

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
                Button { onAction?(action) } label: {
                    Label(tr("Zobacz w logach"), systemImage: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.wegaHoney)
                .accessibilityLabel(tr("Zobacz w logach"))
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
