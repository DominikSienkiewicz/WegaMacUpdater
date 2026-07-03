import SwiftUI
import MacUpdaterCore

/// Right-hand detail panel for the Update list (**I-2**): shows the header for
/// whichever update is currently selected via row-tap. Content/actions/Trust
/// panel are later tasks (I-3/I-4) — this scaffold only renders the header and
/// an empty state.
struct InspectorPane: View {
    let update: InspectedUpdate?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let update {
                header(for: update)
            } else {
                emptyState
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(16)
        .background(Color.wegaHoney.opacity(0.02))
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(tr("Wybierz aktualizację, aby zobaczyć szczegóły"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: Header

    /// Everything `headerContent` needs to render — bundled into one value so the
    /// view function stays under SwiftLint's parameter-count budget.
    private struct HeaderInfo {
        let iconPath: URL?
        let fallbackName: String
        let name: String
        let from: String
        let to: String
        let emphasis: VersionEmphasisKind
        let sourceBadge: WegaBadge
    }

    @ViewBuilder
    private func header(for update: InspectedUpdate) -> some View {
        switch update {
        case .outdated(let item, let iconPath):
            headerContent(HeaderInfo(
                iconPath: iconPath,
                fallbackName: item.name,
                name: item.name,
                from: item.from ?? "—",
                to: item.to ?? "—",
                emphasis: versionEmphasis(
                    changeKind: versionChangeKind(from: item.from ?? "", to: item.to ?? ""),
                    isSecurityFix: false,
                    requiresForce: false
                ),
                sourceBadge: WegaBadge(label: kindLabel(item.kind), variant: kindVariant(item.kind))
            ))
        case .manual(let app):
            let isSecurity = app.releaseNotes.map { ReleaseNotesTriage.heuristic($0).isLikelySecurityFix } ?? false
            headerContent(HeaderInfo(
                iconPath: app.path,
                fallbackName: app.name,
                name: app.name,
                from: app.installedVersion ?? "—",
                to: app.availableVersion ?? "—",
                emphasis: versionEmphasis(
                    changeKind: versionChangeKind(from: app.installedVersion ?? "", to: app.availableVersion ?? ""),
                    isSecurityFix: isSecurity,
                    requiresForce: false
                ),
                sourceBadge: WegaBadge(label: sourceLabel(app.source), color: app.source.provenance.badgeColor)
            ))
        }
    }

    @ViewBuilder
    private func headerContent(_ info: HeaderInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let iconPath = info.iconPath {
                AppIcon(path: iconPath, size: 40)
            } else {
                PackageLetterIcon(name: info.fallbackName, size: 40)
            }
            Text(info.name)
                .font(.system(size: 16, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            VersionArrow(from: info.from, to: info.to, emphasis: info.emphasis)
            info.sourceBadge
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    /// Short kind label for an `OutdatedItem` — matches the task's requested
    /// "Homebrew" / "App Store" / "npm" wording (coarser than `ScanLog`'s labels,
    /// which distinguish formula vs. cask).
    private func kindLabel(_ kind: OutdatedItem.Kind) -> String {
        switch kind {
        case .formula, .cask: return "Homebrew"
        case .appStore:       return "App Store"
        case .npm:            return "npm"
        }
    }

    /// Badge colour variant matching the kind label above.
    private func kindVariant(_ kind: OutdatedItem.Kind) -> WegaBadgeVariant {
        switch kind {
        case .formula, .cask: return .brew
        case .appStore:       return .appStore
        case .npm:            return .info
        }
    }

    /// Readable source label for a manual update's badge.
    private func sourceLabel(_ source: ManualOutdatedApp.UpdateSource) -> String {
        switch source {
        case .sparkle:            return "Sparkle"
        case .cask(let token):    return token
        case .mas(let appStoreID): return appStoreID
        case .jetbrains(let token): return token
        case .github:             return "GitHub"
        case .synology:           return "Synology"
        case .antigravity:        return "Antigravity"
        case .parallels:          return "Parallels"
        case .googleDrive:        return "Google Drive"
        case .chatgpt:            return "ChatGPT"
        case .postman:            return "Postman"
        case .discord:            return "Discord"
        case .signal:             return "Signal"
        case .chrome:             return "Chrome"
        }
    }
}
