import SwiftUI
import MacUpdaterCore

/// C2 stage 4 — the summary's „Do dokończenia u producenta”: exactly what the band's „U
/// producenta” counts (`handOffCount(for: .all)`) — every manual row, security-flagged ones
/// included, then the unresolved Docker and service rows — with the urgency grouping's closures,
/// so its actions (Otwórz aplikację, GitHub Releases, …) work as they do on the list.
///
/// Its own file, apart from `UpdateRunSummaryList`, because these rows stay inspectable while
/// the summary's own rows are not.
struct UpdateRunHandOffGroup: View {
    @EnvironmentObject private var scan: ScanStore
    /// `UpdateView.requestPinManual`, which owns the pin sheet.
    let onPinManual: (ManualOutdatedApp) -> Void

    var body: some View {
        if !scan.externalManualUpdates.isEmpty {
            ManualUpdateSection(
                items: scan.externalManualUpdates, busyToken: scan.manualBusy,
                onInstall: { token in Task { await scan.installManual(token: token) } },
                title: tr("Do dokończenia u producenta"), tint: .wegaToffee,
                inspectedKey: scan.inspectedKey, onIgnore: scan.ignoreManual,
                onPin: onPinManual, onSkip: scan.skipManual,
                onInspect: { scan.inspectedKey = "m:" + $0.path.path }
            )
        }
        ForEach(scan.unresolvedDockerItems) { item in
            UnresolvedDockerUpdateRow(item: item) { scan.inspectedKey = item.key }
        }
        ForEach(scan.unresolvedServiceItems) { item in
            UnresolvedServiceUpdateRow(item: item) { scan.inspectedKey = item.key }
        }
    }
}
