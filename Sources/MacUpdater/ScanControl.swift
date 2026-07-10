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
                HStack(spacing: 8) {
                    ProgressView(value: scan.progress?.fractionCompleted ?? 0)
                        .progressViewStyle(.linear)
                        .tint(Color.wegaHoney)
                        .frame(width: 90)
                    if scan.progress?.isCancellable == true {
                        Button(tr("Anuluj")) { scan.cancelScan() }
                            .buttonStyle(.glass)
                    }
                }
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
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: scan.status)
    }
}
