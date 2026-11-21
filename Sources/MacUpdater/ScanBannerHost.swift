import AppKit
import SwiftUI
import MacUpdaterCore

/// The one place `scan.banner` is drawn, shared by the destinations that raise banners.
///
/// Banners used to be rendered only by `UpdateView`, which is invisible on every other
/// destination — so an undo result raised from the Undo screen went nowhere the user could see.
struct ScanBannerHost: View {
    @EnvironmentObject private var scan: ScanStore
    @Environment(\.openSettings) private var openSettings

    var onNavigate: ((SidebarTab) -> Void)?

    init(onNavigate: ((SidebarTab) -> Void)?) {
        self.onNavigate = onNavigate
    }

    var body: some View {
        if let banner = scan.banner {
            BannerView(
                data: banner,
                onAction: perform,
                onClose: { scan.dismissBanner() }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func perform(_ action: BannerAction) {
        switch action {
        case .openLogs: onNavigate?(.logs)
        case .openSettings, .openTouchIDCard:
            SettingsRoute.shared.open(.touchID, with: openSettings)
        case .openAppManagementSettings:
            // REL-05 — straight to the pane that grants the permission,
            // not to Wega's own settings, which cannot grant anything.
            NSWorkspace.shared.open(AppManagementSettings.paneURL)
        case .reinstallCask(let token):
            Task { await scan.reinstallManual(token: token) }
        case .trustPublisher:
            Task { await scan.trustNewPublisher(for: action) }
        }
    }
}
