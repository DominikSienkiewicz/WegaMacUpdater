import SwiftUI
import MacUpdaterCore

// MARK: - Shared scan-directory helper

/// The built-in roots (/Applications, ~/Applications), any user-added roots, and their
/// non-.app subdirectories down to the configured recursion depth, minus exclusions
/// (UX-16). Implementation lives in `MacUpdaterCore.AppScanDirectories` so the menu-bar
/// agent shares it; the user's configuration is read from `UserDefaults` on each call so a
/// change in Settings takes effect on the next scan.
func buildScanDirs() -> [URL] {
    AppScanDirectories.all(configuration: ScanConfigurationStore.resolvedConfiguration())
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
        // UX-15 — the shared callout's urgent level; UX-07's three-line cap lives there too,
        // so a raw error message cannot stretch the banner past the window.
        WegaCallout(.urgent, title: message)
            .lineLimit(3)
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

enum WegaBadgeRole {
    case status, source
}

struct WegaBadge: View {
    let label: String
    var variant: WegaBadgeVariant = .brew
    var role: WegaBadgeRole = .status
    private var explicitColor: Color?

    init(label: String, variant: WegaBadgeVariant = .brew, role: WegaBadgeRole = .status) {
        self.label = label
        self.variant = variant
        self.role = role
        self.explicitColor = nil
    }

    /// Renders with an explicit colour instead of a `WegaBadgeVariant` — same
    /// layout/metrics as the variant initializer, used for provenance-based
    /// colour-coding where the colour isn't one of the fixed variants.
    init(label: String, color: Color, role: WegaBadgeRole = .status) {
        self.label = label
        self.variant = .brew
        self.explicitColor = color
        self.role = role
    }

    private var fg: Color { explicitColor ?? variant.fg }
    private var bg: Color { explicitColor?.opacity(0.12) ?? variant.bg }

    var body: some View {
        Text(label)
            .font(.wega(.subheadline, weight: .medium))
            .foregroundStyle(role == .source ? Color.secondary : fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(role == .source ? Color.primary.opacity(0.04) : bg,
                        in: RoundedRectangle(cornerRadius: 6))
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

// MARK: - Tri-state selection checkbox

/// The checkbox that selects a whole collection of rows at once — the list-wide
/// "Zaznacz wszystko" and the per-group checkbox in each card header.
///
/// It renders the same queue circle, at the same size, as `PackageRow`'s own control, because
/// all three sit in one column (`WegaLayout.selectionColumnInset`): a bigger or differently
/// placed circle reads as an unrelated control rather than as "the same choice, wider".
struct SelectionCheckbox: View {
    let state: SelectAllState
    let accessibilityLabel: String
    var accessibilityValue: String? = nil
    let toggle: @MainActor @Sendable () -> Void

    var body: some View {
        Button(action: toggle) {
            QueueCircleControlLabel(state: QueueCircleState(state))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(state == .all ? [.isToggle, .isSelected] : .isToggle)
        .accessibilityValue(accessibilityValue ?? selectionAccessibilityValue(state == .all))
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
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: WegaLayout.cardRadius))
    }
}

// MARK: - WegaCardHeader

/// The standard header row for a `WegaCard`: a tinted SF Symbol, a 13-pt semibold title,
/// an optional inline count and note, an optional caption line, and an optional trailing
/// accessory. It replaces the ~20 hand-rolled copies of the same
/// `HStack + padding + bottom divider` chrome, so the card-header layout has a single
/// definition (ARCH-07g).
///
/// Layout, matching the pattern it replaces:
///
///     [icon] title [count] [note] ──Spacer── [trailing]
///
/// with an optional `caption` rendered on a second line under the row. `count` and `note`
/// sit on the left next to the title; `trailing` sits on the right, after the spacer.
struct WegaCardHeader<Trailing: View>: View {
    let icon: String
    let tint: AnyShapeStyle
    let title: String
    /// Tints the title text with `tint` too — the `Label`-style look the settings cards used.
    /// Otherwise the title keeps the default primary colour, like every other card.
    let titleTinted: Bool
    /// Monospaced count shown right after the title (how many items the card lists).
    let count: Int?
    /// Short tertiary note shown after the count (e.g. "ryzyko rozjazdu wersji w PATH").
    let note: String?
    /// Optional one-line explanation rendered under the header row.
    let caption: String?
    /// Optional checkbox that selects or clears every row this card lists, rendered ahead
    /// of the icon so it lands in the same column as the row checkboxes below.
    let selection: SelectionCheckbox?
    let trailing: Trailing

    init(icon: String, tint: Color = .wegaHoney, title: String, titleTinted: Bool = false,
         count: Int? = nil, note: String? = nil, caption: String? = nil,
         selection: SelectionCheckbox? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.tint = AnyShapeStyle(tint)
        self.title = title
        self.titleTinted = titleTinted
        self.count = count
        self.note = note
        self.caption = caption
        self.selection = selection
        self.trailing = trailing()
    }

    var body: some View {
        // The checkbox is a sibling of the whole text block, not of the header line alone,
        // so the caption indents under the title by construction — no glyph measuring, and
        // nothing to re-tune when the system text size changes.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let selection {
                selection.padding(.trailing, WegaLayout.checkboxSpacing)
            }
            VStack(alignment: .leading, spacing: 4) {
                headerRow
                if let caption {
                    Text(caption)
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, WegaLayout.cardPadding)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Divider().opacity(0.3) }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(titleTinted ? tint : AnyShapeStyle(.secondary))
            Text(title)
                .font(.wega(.headline))
                .foregroundStyle(titleTinted ? tint : AnyShapeStyle(.primary))
            if let count {
                Text("\(count)")
                    .font(.wega(.callout, monospaced: true))
                    .foregroundStyle(.tertiary)
            }
            if let note {
                Text(note).font(.wega(.subheadline)).foregroundStyle(.tertiary)
            }
            Spacer()
            trailing
        }
    }
}

extension WegaCardHeader {
    /// A tint that is not one of the palette `Color`s (e.g. `.tertiary` for a muted header).
    init(icon: String, tint: AnyShapeStyle, title: String, titleTinted: Bool = false,
         count: Int? = nil, note: String? = nil, caption: String? = nil,
         selection: SelectionCheckbox? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.titleTinted = titleTinted
        self.count = count
        self.note = note
        self.caption = caption
        self.selection = selection
        self.trailing = trailing()
    }
}

extension WegaCardHeader where Trailing == EmptyView {
    init(icon: String, tint: Color = .wegaHoney, title: String, titleTinted: Bool = false,
         count: Int? = nil, note: String? = nil, caption: String? = nil,
         selection: SelectionCheckbox? = nil) {
        self.init(icon: icon, tint: tint, title: title, titleTinted: titleTinted,
                  count: count, note: note, caption: caption, selection: selection) { EmptyView() }
    }

    init(icon: String, tint: AnyShapeStyle, title: String, titleTinted: Bool = false,
         count: Int? = nil, note: String? = nil, caption: String? = nil,
         selection: SelectionCheckbox? = nil) {
        self.init(icon: icon, tint: tint, title: title, titleTinted: titleTinted,
                  count: count, note: note, caption: caption, selection: selection) { EmptyView() }
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
    /// UX-03 — the tile's palette, exposed so the contrast guard measures the code instead of
    /// restating its numbers.
    ///
    /// The fill used to be `brightness: 0.65`, which put the letter at **3.00:1** against it —
    /// below even the 3:1 allowed for large text. The glyph is `size * 0.46` bold, so at the
    /// 40pt tile it is large text and at the default 28pt one it is not: the smallest tile
    /// needed 4.5:1 and no size reached it. Darkening the fill clears the strict threshold at
    /// every size, which is cheaper than making the rule depend on which tile you are looking at.
    static let tileHues: [Double] = [0.08, 0.12, 0.06, 0.10]
    static let tileSaturation: Double = 0.6
    static let tileBrightness: Double = 0.48
    static let letterOpacity: Double = 0.9

    let name: String
    var size: CGFloat = 28

    private var letter: String { String(name.first ?? "?").uppercased() }
    private var bg: Color {
        let h = name.unicodeScalars.reduce(0) { $0 + $1.value } % 4
        return Color(
            hue: Self.tileHues[Int(h)],
            saturation: Self.tileSaturation,
            brightness: Self.tileBrightness
        )
    }

    var body: some View {
        Text(letter)
            // UX-03-fixed-size: a glyph drawn inside a fixed `size × size` tile, not a piece
            // of running text. It is derived from the tile it has to fit; a semantic style
            // would grow past the tile at the larger text sizes and clip instead of reflow.
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white.opacity(Self.letterOpacity))
            .frame(width: size, height: size)
            .background(bg, in: RoundedRectangle(cornerRadius: size * 0.22))
    }
}

// MARK: - VersionArrow

extension VersionEmphasisKind {
    /// Maps semantic emphasis to a Wega palette colour. Normal = primary, major =
    /// caramel, security = danger red, forced (brew --force) = toffee.
    var versionColor: Color {
        switch self {
        case .normal:   return .primary
        case .major:    return .wegaCaramel
        case .security: return .wegaDanger
        case .forced:   return .wegaToffee
        }
    }
}

struct VersionArrow: View {
    /// `.row` keeps the pair to one readable line; `.full` shows the exact strings and may wrap.
    enum Style { case row, full }

    let from: String
    let to: String
    var emphasis: VersionEmphasisKind = .normal
    var style: Style = .row

    var body: some View {
        switch style {
        case .row:
            let shown = VersionDisplay.pair(from: from, to: to)
            arrow(from: shown.from, to: shown.to)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\(from) → \(to)")
        case .full:
            arrow(from: from, to: to)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func arrow(from: String, to: String) -> some View {
        HStack(spacing: 5) {
            Text(from).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary).font(.caption2)
            Text(to).foregroundStyle(emphasis.versionColor).fontWeight(.medium)
        }
        .font(.wega(.callout, monospaced: true))
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
    /// UX-18 — the row's source, shown when its card mixes sources (grouping by urgency).
    var source: String? = nil
    /// UX-18 — why the rollback net cannot cover this row, for sources that keep no previous
    /// version. Shown as a muted shield on the row when its card has no per-source caption.
    var rollbackUnavailableReason: String? = nil
    var onToggle: (@MainActor @Sendable () -> Void)? = nil
    var onSelect: (() -> Void)? = nil
    /// M5 — the ignore / pin actions, previously reachable only by right-click.
    var onIgnore: (() -> Void)? = nil
    var onPin:    (() -> Void)? = nil
    /// UX-12 — skip just the version on offer; a later release surfaces again.
    var onSkip:   (() -> Void)? = nil
    /// F3 — per-app opt-in for unattended background upgrades. Offered only where the
    /// rollback net covers the cask, so the menu never proposes what Wega cannot undo.
    var backgroundUpdateToken: String? = nil
    /// UXP-21 — whether this row is its group's one Tab stop; the others are reached by arrow.
    var isTabStop = true
    /// UXP-21 — moves focus to the neighbouring row; `false` at the group's edge.
    var onMove: ((RowMoveDirection) -> Bool)? = nil

    @Environment(\.isEnabled) private var isEnabled
    /// Space on a focused ⋯ opens its menu; reaching the row, it would queue the update.
    @FocusState private var menuFocused: Bool

    var body: some View {
        HStack(spacing: WegaLayout.checkboxSpacing) {
            if let onToggle {
                Toggle(isOn: selectionToggleBinding(isOn: isSelected, toggle: onToggle)) {
                    EmptyView()
                }
                .toggleStyle(WegaQueueToggleStyle())
                .accessibilityLabel(trf("Kolejka: %@", name))
                .focusable(false)
            }
            if let path = iconPath {
                AppIcon(path: path, size: WegaLayout.updateIconSize)
            } else {
                PackageLetterIcon(name: name, size: WegaLayout.updateIconSize)
            }
            UpdateRowColumns {
                identity
            } version: {
                versionDetails
            }
            if onIgnore != nil || onPin != nil || onSkip != nil {
                Menu {
                    if let onIgnore {
                        Button(action: onIgnore) { Label(tr("Nie aktualizuj"), systemImage: "bell.slash") }
                    }
                    if let onSkip {
                        Button(action: onSkip) { Label(tr("Pomiń tę wersję"), systemImage: "forward.end") }
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
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .focusable(isTabStop)
                .focused($menuFocused)
                .accessibilityLabel(trf("Więcej działań dla %@", name))
            }
        }
        .padding(.horizontal, WegaLayout.cardPadding)
        .padding(.vertical, WegaLayout.updateRowPadding)
        .queueRowSelection(isInspected)
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .focusable(onSelect != nil && isTabStop)
        // A row focused before a run or a scan disabled the list keeps its focus; it answers nothing.
        .onKeyPress(.return) {
            guard isEnabled else { return .ignored }
            return PackageRowKeyboardBehavior.handle(
                .inspect,
                onSelect: onSelect,
                onToggle: onToggle
            ) ? .handled : .ignored
        }
        .onKeyPress(.space) {
            guard isEnabled else { return .ignored }
            guard !menuFocused else { return .ignored }
            return PackageRowKeyboardBehavior.handle(
                .toggleSelection,
                onSelect: onSelect,
                onToggle: onToggle
            ) ? .handled : .ignored
        }
        .onKeyPress(.upArrow) { onMove?(.up) == true ? .handled : .ignored }
        .onKeyPress(.downArrow) { onMove?(.down) == true ? .handled : .ignored }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PackageRowAccessibility.label(name: name, token: shownToken, from: currentVersion, to: latestVersion,
                                                          source: source, rollback: rollback,
                                                          rollbackUnavailable: rollbackUnavailableReason != nil, isQueued: isSelected))
        .accessibilityHint(PackageRowAccessibility.hint(isQueued: isSelected))
        .accessibilityActions {
            if isEnabled {
                if let onSelect { Button(tr("Pokaż szczegóły"), action: onSelect) }
                if let onIgnore { Button(tr("Nie aktualizuj"), action: onIgnore) }
                if let onSkip { Button(tr("Pomiń tę wersję"), action: onSkip) }
            }
        }
    }

    /// The token line under the name, only when the token says something the name does not.
    private var shownToken: String? {
        token == name ? nil : token
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            if let token = shownToken {
                Text(source.map { "\(token) · \($0)" } ?? token)
                    .font(.wega(.caption, monospaced: true))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let source {
                Text(source)
                    .font(.wega(.footnote))
                    .foregroundStyle(.secondary)
            }
            if rollback == .protected {
                RollbackScopeNotice(scope: RollbackProtection.scope(token: token ?? name), compact: true)
            }
        }
    }

    private var versionDetails: some View {
        HStack(spacing: 8) {
            if let rollback {
                RollbackBadge(verdict: rollback, scope: RollbackProtection.scope(token: token ?? name))
            } else if let rollbackUnavailableReason {
                Image(systemName: "shield.slash")
                    .font(.wega(.callout))
                    .foregroundStyle(.tertiary)
                    .help(rollbackUnavailableReason)
                    .accessibilityLabel(rollbackUnavailableReason)
            }
            if let from = currentVersion, let to = latestVersion {
                let kind = versionChangeKind(from: from, to: to)
                let emphasis = versionEmphasis(changeKind: kind,
                                               isSecurityFix: securityFix,
                                               requiresForce: requiresForce)
                VersionArrow(from: from, to: to, emphasis: emphasis)
            } else if let version = currentVersion ?? latestVersion {
                Text(version)
                    .font(.wega(.caption, monospaced: true))
                    .foregroundStyle(.secondary)
            }
        }
    }

}

// MARK: - Rollback badge (M5)

/// Describes app-bundle rollback capability without implying Docker environment recovery.
private struct RollbackBadge: View {
    let verdict: RollbackProtection.Verdict
    let scope: RollbackProtection.Scope

    var body: some View {
        switch verdict {
        case .protected:
            Image(systemName: "shield.lefthalf.filled")
                .font(.wega(.callout))
                .foregroundStyle(Color.wegaSuccess)
                .help(RollbackScopePresentation.notice(for: scope)?.localizedDescription
                      ?? tr("Przed aktualizacją robię kopię. Jeśli nowa wersja nie przejdzie testu, wracam do poprzedniej."))
                .accessibilityLabel(tr(RollbackScopePresentation.notice(for: scope)?.title ?? "Chronione automatycznym cofnięciem"))
        case .unprotected:
            Image(systemName: "shield.slash")
                .font(.wega(.callout))
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
                    .font(.wega(.title, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.wega(.body))
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

// MARK: - Selection checkbox (UX-02)

/// The selection checkbox: Wega's glyph, macOS's semantics.
///
/// A `Button` drawing a checkmark reads to VoiceOver as a *button that happens to carry a
/// value*; the control is a checkbox, and saying so is the difference between "przycisk,
/// Zaznaczone" and "pole wyboru, zaznaczone". Wrapping the selection in a real `Toggle`
/// moves the role, the state and the space-bar activation out of each call site and into
/// the system — the style below exists only so the honey `checkmark.square.fill` survives
/// the change. It draws; `Toggle` means.
///
/// `.toggleStyle(.checkbox)` would give the same semantics without a custom style, at the
/// cost of replacing that glyph with the system checkbox in every list.
struct WegaCheckboxToggleStyle: ToggleStyle {
    /// Matches the glyph to the row it sits in — rows differ in density, and the checkbox
    /// has to line up with the text beside it.
    var glyphFont: Font = .body
    var spacing: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: spacing) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.wegaHoney : .secondary)
                    .font(glyphFont)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A custom style owns the whole rendering, so it owns the semantics too: without
        // these the control would go back to announcing itself as a plain button.
        .accessibilityAddTraits(configuration.isOn ? [.isToggle, .isSelected] : .isToggle)
        .accessibilityValue(selectionAccessibilityValue(configuration.isOn))
    }
}

/// Adapts a "flip it" callback to the two-way binding `Toggle` needs. The new value is
/// discarded on purpose: the owner of the selection decides what toggling means, and every
/// call site here already has that decision written down.
@MainActor
func selectionToggleBinding(
    isOn: Bool,
    toggle: @escaping @MainActor @Sendable () -> Void
) -> Binding<Bool> {
    Binding(get: { isOn }, set: { _ in toggle() })
}

// MARK: - BannerData + BannerView

enum BannerAction: Equatable {
    case openLogs, openSettings, openAppManagementSettings
    /// Runs `brew reinstall --cask` for the token through the protected adoption flow.
    case reinstallCask(token: String)
    /// Accepts the cask's new publisher Team ID after the user confirms it. `teamID` is the ID
    /// the warning showed, so a bundle re-signed since then is refused rather than trusted.
    case trustPublisher(token: String, teamID: String?)
}

struct BannerData: Equatable {
    enum Variant { case success, danger }
    let variant: Variant
    let title: String
    let message: String
    var action: BannerAction? = nil
    var autoDismiss: Bool = true
    /// The whole message when `message` is the shortened form (a long list of names).
    var fullMessage: String? = nil
}

/// When a banner may take itself off the screen.
///
/// A banner that only reports something finished — no failure to understand, no button to
/// press — has said everything it has to say the moment it is read, and then it is just
/// occupying the top of the window. Anything else waits: a failure needs reading, and a
/// banner carrying an action needs the action to still be there when the user reaches for it.
///
/// The rule is written against the action as well as the variant, so a future success banner
/// that grows a button does not start vanishing out from under the cursor. The two banners
/// raised as *sticky* (a failed rollback, a changed publisher) are both `.danger`, so they
/// are excluded by this rule already and need no second channel.
enum BannerDismissal {
    /// Long enough to read two short lines, short enough not to become furniture.
    static let delay: Duration = .seconds(3)

    static func isSelfDismissing(_ data: BannerData) -> Bool {
        data.autoDismiss && data.variant == .success && data.action == nil
    }

    /// Leaving is animated; arriving is not. A confirmation should be on screen the instant
    /// the work finishes, and animating that would mean wrapping all 26 `showBanner` calls.
    static func removal(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 0.82)
    }

    /// Under "Ogranicz ruch" the banner fades without travelling — still a transition, just
    /// not a moving one.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
}

struct BannerView: View {
    let data: BannerData
    var onAction: ((BannerAction) -> Void)? = nil
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // UX-15 — drawn through the shared callout; UX-07's three-line cap on the message
        // lives there. A failure's full, untranslated `stderr` stays in the log (see
        // "Pokaż w logach").
        WegaCallout(
            WegaCalloutLevel(banner: data.variant),
            title: data.title,
            message: data.message,
            fullMessage: data.fullMessage,
            onClose: { close() },
            actions: { actionButton }
        )
        .transition(BannerDismissal.transition(reduceMotion: reduceMotion))
        // Keyed on the banner itself: a banner replaced by a newer one restarts the countdown
        // rather than inheriting what was left of the previous one's.
        .task(id: data) {
            guard BannerDismissal.isSelfDismissing(data) else { return }
            try? await Task.sleep(for: BannerDismissal.delay)
            guard !Task.isCancelled else { return }
            close()
        }
    }

    /// The dismissal animation is driven from inside the banner, so every host gets the
    /// transition without wrapping its own state change — the three views that show banners
    /// each own that state differently.
    private func close() {
        withAnimation(BannerDismissal.removal(reduceMotion: reduceMotion)) { onClose() }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let action = data.action {
            Button { onAction?(action) } label: {
                Label(Self.label(for: action), systemImage: Self.symbol(for: action))
                    .font(.wega(.callout, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.wegaHoney)
            .accessibilityLabel(Self.label(for: action))
        }
    }

    private static func label(for action: BannerAction) -> String {
        switch action {
        case .openLogs:     return tr("Pokaż w logach")
        case .openSettings: return tr("Włącz Touch ID")
        case .openAppManagementSettings: return tr("Otwórz ustawienia prywatności")
        case .reinstallCask: return tr("Przeinstaluj przez Brew")
        case .trustPublisher: return tr("Zaufaj nowemu podpisowi")
        }
    }

    private static func symbol(for action: BannerAction) -> String {
        switch action {
        case .reinstallCask: return "arrow.clockwise.circle"
        case .trustPublisher: return "checkmark.shield"
        case .openLogs, .openSettings, .openAppManagementSettings: return "info.circle"
        }
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

// MARK: - WegaDisclosure

/// Rozwijanie, w którym całym celem kliknięcia jest nagłówek.
///
/// `DisclosureGroup` na macOS przełącza się wyłącznie z chevronu, a etykieta obok — mimo że
/// wygląda na część kontrolki — nic nie robi. Tutaj chevron i etykieta siedzą w jednym
/// `Button`, więc trafienie w dowolne miejsce nagłówka przełącza sekcję.
///
/// UX-02: `Button`, nie `.onTapGesture`. Rola dla VoiceOver, fokus i aktywacja spacją
/// przychodzą razem z nim, a gest oblałby guard w `UX02ActionableControlsTests`.
///
/// Kolejność `content` przed `label` powiela `DisclosureGroup(isExpanded:content:label:)`,
/// żeby podmiana w istniejących miejscach była zmianą nazwy typu, a nie przepisywaniem.
struct WegaDisclosure<Content: View, Label: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    label()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(tr(isExpanded ? "rozwinięte" : "zwinięte"))

            if isExpanded { content() }
        }
    }
}

// MARK: - Update row columns (UX-14)

/// The name and version columns every row on the Updates screen shares — package rows and
/// manually updated apps alike — so versions line up down a card instead of each row kind
/// placing them its own way. Too narrow for one line, the version drops under the name.
struct UpdateRowColumns<Identity: View, Version: View>: View {
    private let identity: Identity
    private let version: Version

    init(@ViewBuilder _ identity: () -> Identity, @ViewBuilder version: () -> Version) {
        self.identity = identity()
        self.version = version()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                identity.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                version
                    .frame(minWidth: WegaLayout.versionColumnWidth, maxWidth: WegaLayout.versionColumnMaxWidth, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                identity
                version
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
