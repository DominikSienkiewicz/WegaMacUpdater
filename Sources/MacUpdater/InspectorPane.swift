import SwiftUI
import MacUpdaterCore

/// Right-hand detail panel for the Update list: shows the header (**I-2**) plus
/// trust/details/What's-New/actions (**I-3**, **I-4**) for whichever update is currently
/// selected via row-tap. The Trust panel (Team ID / signature / checksum, `TrustPanel.swift`)
/// is the FINAL inspector increment, **I-4**.
struct InspectorPane: View {
    let update: InspectedUpdate?
    /// Cask token currently mid-install, forwarded from `UpdateView` so
    /// `ManualUpdateActionView` shows the same busy state as the list row.
    var busyToken: String? = nil
    /// Kicks off a manual cask install, forwarded from `UpdateView`. Defaulted so the
    /// empty-state / preview paths don't need to supply one.
    var onInstall: (String) -> Void = { _ in }
    /// Homebrew cask download metadata (token → info), forwarded from `UpdateView` so the
    /// Trust panel's checksum signal can look up a manual cask's checksum presence.
    /// Defaulted so previews / the empty-state path still compile.
    var caskDownloads: [String: CaskDownloadInfo] = [:]

    var body: some View {
        Group {
            if let update {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(for: update)
                        VStack(alignment: .leading, spacing: 16) {
                            trustSection(for: update)
                            detailsSection(for: update)
                            whatsNewSection(for: update)
                            actionsSection(for: update)
                        }
                        .padding(.top, 16)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    emptyState
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(16)
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
                PackageLetterIcon(name: info.name, size: 40)
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

    // MARK: Section heading

    /// Small consistent heading used by the three body sections below.
    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    /// One label→value row for the "Szczegóły" section — label fixed-width so values align.
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
        }
    }

    // MARK: 3a. Trust (I-4)

    /// Resolves the Trust panel's inputs per case — only a manual app has a real `.app` path,
    /// so only it gets real signals; an `OutdatedItem` always probes with `path: nil` and
    /// therefore always renders `.unavailable` (see `TrustPanel.probe`'s honesty guard).
    @ViewBuilder
    private func trustSection(for update: InspectedUpdate) -> some View {
        switch update {
        case .outdated(let item, _):
            TrustPanel(path: nil, caskChecksum: nil, caskToken: nil, probeKey: item.key)
        case .manual(let app):
            TrustPanel(
                path: app.path,
                caskChecksum: caskChecksumToken(of: app.source).flatMap { caskDownloads[$0]?.hasChecksum },
                caskToken: caskChecksumToken(of: app.source),
                probeKey: "m:" + app.path.path
            )
        }
    }

    // MARK: 3b. Details

    @ViewBuilder
    private func detailsSection(for update: InspectedUpdate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(tr("Szczegóły"))
            switch update {
            case .outdated(let item, _):
                detailRow(tr("Zainstalowana"), item.from ?? "—")
                detailRow(tr("Dostępna"), item.to ?? "—")
                detailRow(tr("Typ"), kindLabel(item.kind))
            case .manual(let app):
                detailRow(tr("Zainstalowana"), app.installedVersion ?? "—")
                detailRow(tr("Dostępna"), app.availableVersion ?? "—")
                detailRow(tr("Pochodzenie"), originLabel(app.origin))
                HStack(alignment: .top, spacing: 8) {
                    Text(tr("Ścieżka"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    Text(app.path.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(app.path.path)
                }
            }
        }
    }

    /// Readable label for an installed app's origin — used by the details section.
    private func originLabel(_ origin: AppOrigin) -> String {
        switch origin {
        case .brew:     return "Homebrew"
        case .appStore: return "App Store"
        case .npm:      return "npm"
        case .manual:   return tr("Zainstalowane ręcznie")
        }
    }

    // MARK: 3c. What's New

    @ViewBuilder
    private func whatsNewSection(for update: InspectedUpdate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(tr("Co nowego"))
            switch update {
            case .outdated:
                Text(tr("Informacje o zmianach niedostępne dla tego źródła"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            case .manual(let app):
                whatsNewContent(notes: app.releaseNotes)
            }
        }
    }

    @ViewBuilder
    private func whatsNewContent(notes: String?) -> some View {
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if ReleaseNotesTriage.heuristic(notes).isLikelySecurityFix {
                    Label(tr("możliwa poprawka bezpieczeństwa"), systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.wegaDanger)
                }
                Text(notes)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(tr("Brak informacji o zmianach"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: 3d. Actions

    @ViewBuilder
    private func actionsSection(for update: InspectedUpdate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(tr("Akcje"))
            switch update {
            case .outdated:
                Text(tr("Aktualizowane zbiorczo — zaznacz na liście i użyj „Zaktualizuj wybrane”."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .manual(let app):
                ManualUpdateActionView(item: app, busyToken: busyToken, onInstall: onInstall)
            }
        }
    }
}
