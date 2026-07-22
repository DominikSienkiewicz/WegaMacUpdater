import SwiftUI
import MacUpdaterCore

/// The scan lifecycle as one toolbar control.
///
/// `.glassEffectID` morphs glass between states only when both states live inside the same
/// `GlassEffectContainer`. The old buttons sat in `readyView` and `checkingView` — different
/// branches of a `switch`, no common parent — so they could not morph. Hoisting the control
/// into the toolbar gives it one container, one namespace, and the morph for free.
struct ScanControl: View {
    @EnvironmentObject private var scan: ScanStore
    let namespace: Namespace.ID

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            if scan.status == .checking {
                // The progress bar lives in the scan view's centre (`checkingView`), next to
                // the phase label and the sniffing scene — one bar, not two. The toolbar keeps
                // only the action: cancelling the scan it started.
                Button(tr("Anuluj")) { scan.cancelScan() }
                    .buttonStyle(.glass)
                    .glassEffectID("scan", in: namespace)
            } else {
                Button { scan.startCheck() } label: {
                    Label(tr("Sprawdź teraz"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.glassProminent)
                .tint(Color.wegaHoney)
                .foregroundStyle(Color.wegaInk)
                .glassEffectID("scan", in: namespace)
                // A rescan during an install would race the upgrade it is meant to describe.
                // The button this control replaced carried the same guard.
                .disabled(scan.updating)
            }
        }
        // Keep the toolbar item's geometry constant while its action changes. A width change
        // here invalidates the window safe area; combined with NavigationSplitView that can
        // make AppKit re-run constraints until it aborts the process.
        .frame(width: 135)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: scan.status)
    }
}
