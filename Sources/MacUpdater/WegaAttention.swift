import SwiftUI

/// UXP-27 — when Wega puts her ball down. She plays in empty states, during scans and on
/// success; while something asks for the user's attention she sits still, and the sidebar
/// card's chase resumes only once it is gone.
enum WegaAttention {
    /// The ball waits while an error, a run (password and publisher prompts come from it) or a dialog is open.
    static func holdsBall(bannerVariant: BannerData.Variant?, isUpdating: Bool, dialogOpen: Bool) -> Bool {
        bannerVariant == .danger || isUpdating || dialogOpen
    }
}

/// Whether any screen below `DetailColumn` has a confirmation or an error open. One open
/// dialog is enough, so the values combine with "or".
struct WegaAttentionKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Reports to `DetailColumn` that this screen holds the user's attention. Attach it to the
    /// screen's drawn root, beside its `.sheet` / `.alert`, never to a view that may be empty.
    ///
    /// Added to what the content already reports rather than replacing it, as
    /// `preference(key:value:)` would: Updates' own report must not hide the Docker Desktop
    /// confirmation drawn inside it.
    func wegaAttention(_ held: Bool) -> some View {
        transformPreference(WegaAttentionKey.self) { $0 = $0 || held }
    }
}
