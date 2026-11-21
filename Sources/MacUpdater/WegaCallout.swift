import SwiftUI

// MARK: - Callout level (UX-15)

/// How much a notice matters. The level alone decides how a notice looks — its tint and its
/// symbol — so two notices of the same weight can no longer look unrelated, and two of
/// different weight never differ by colour alone.
enum WegaCalloutLevel: CaseIterable, Equatable {
    case info, success, warning, urgent

    /// The result banners speak in two variants; a failure is urgent, a confirmation is not.
    init(banner: BannerData.Variant) {
        switch banner {
        case .success: self = .success
        case .danger:  self = .urgent
        }
    }

    var symbolName: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .urgent:  return "exclamationmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info:    return .wegaInfo
        case .success: return .wegaSuccess
        case .warning: return .wegaHoney
        case .urgent:  return .wegaDanger
        }
    }
}

// MARK: - Callout

/// UX-15 — the one shape every notice on the main screens takes: a tinted rounded field with
/// the level's symbol, a title, an optional message capped at three lines (UX-07: a raw
/// `stderr` must never stretch it past the window), optional detail, the notice's actions
/// and, when it can be dismissed, a close button.
struct WegaCallout<Detail: View, Actions: View>: View {
    let level: WegaCalloutLevel
    let title: String
    var message: String?
    /// The untruncated message; when set, a "show all" button expands it in place.
    var fullMessage: String?
    @State private var showsAll = false
    /// Overrides the level's symbol where the notice has a more specific one (a trash can for
    /// a cleanup offer); the tint still comes from the level.
    var symbol: String?
    var onClose: (() -> Void)?
    let detail: Detail
    let actions: Actions

    init(
        _ level: WegaCalloutLevel,
        title: String,
        message: String? = nil,
        fullMessage: String? = nil,
        symbol: String? = nil,
        onClose: (() -> Void)? = nil,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder actions: () -> Actions
    ) {
        self.level = level
        self.title = title
        self.message = message
        self.fullMessage = fullMessage
        self.symbol = symbol
        self.onClose = onClose
        self.detail = detail()
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol ?? level.symbolName)
                .foregroundStyle(level.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.wega(.callout, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    if showsAll, let fullMessage {
                        Text(fullMessage)
                            .font(.wega(.subheadline))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(message)
                            .font(.wega(.subheadline))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    if fullMessage != nil, !showsAll {
                        Button(tr("Pokaż wszystkie")) { showsAll = true }
                            .buttonStyle(.link)
                            .font(.wega(.subheadline))
                    }
                }
                detail
            }
            Spacer(minLength: 8)
            actions
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(tr("Zamknij"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(level.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .onChange(of: fullMessage) { showsAll = false }
    }
}

extension WegaCallout where Detail == EmptyView {
    init(
        _ level: WegaCalloutLevel,
        title: String,
        message: String? = nil,
        fullMessage: String? = nil,
        symbol: String? = nil,
        onClose: (() -> Void)? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(level, title: title, message: message, fullMessage: fullMessage, symbol: symbol, onClose: onClose,
                  detail: { EmptyView() }, actions: actions)
    }
}

extension WegaCallout where Detail == EmptyView, Actions == EmptyView {
    init(
        _ level: WegaCalloutLevel,
        title: String,
        message: String? = nil,
        fullMessage: String? = nil,
        symbol: String? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.init(level, title: title, message: message, fullMessage: fullMessage, symbol: symbol, onClose: onClose,
                  detail: { EmptyView() }, actions: { EmptyView() })
    }
}
