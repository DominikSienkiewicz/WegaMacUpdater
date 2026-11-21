import AppKit
import MacUpdaterCore
import SwiftUI

/// UX-14 — reports an app Wega has no known way to update. It is the one and only call site of
/// `CatalogIssueBuilder`: the action builds a prefilled GitHub "new issue" URL and hands it to
/// `NSWorkspace`, closing the community-catalog loop from the UI. Inventory draws it as an icon on
/// the app's row; ⌘F's no-source answer on Updates draws it as a link.
struct ReportAppButton: View {
    enum Style { case icon, link }

    let app: ApplicationInfo
    var style: Style = .icon

    var body: some View {
        switch style {
        case .icon:
            Button(action: report) {
                Image(systemName: "plus.bubble")
                    .font(.wega(.subheadline))
                    .foregroundStyle(Color.wegaHoney)
            }
            .buttonStyle(.plain)
            .help(tr("Zgłoś tę aplikację do katalogu"))
            .accessibilityLabel(tr("Zgłoś aplikację"))
        case .link:
            Button(tr("Zgłoś aplikację ›"), action: report)
                .buttonStyle(.link)
                .help(tr("Zgłoś tę aplikację do katalogu"))
                .accessibilityLabel(tr("Zgłoś aplikację"))
        }
    }

    private func report() {
        let builder = CatalogReporting.issueBuilder(for: app)
        guard let url = builder.url(newIssueEndpoint: AppEndpoints.shared.projectNewIssueURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
