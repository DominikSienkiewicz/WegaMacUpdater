import AppKit
import SwiftUI
import XCTest
@testable import WegaMacUpdater

/// A scan changes the toolbar and the split-view detail at the same time. On macOS, allowing
/// the toolbar control's intrinsic size to change during that transition can repeatedly
/// invalidate the window safe area until AppKit aborts the process.
final class ScanControlLayoutTests: XCTestCase {
    @MainActor
    func testCheckingToResultsTransitionKeepsToolbarGeometryStable() {
        let scan = ScanStore()
        scan.status = .checking
        scan.progress = .running(.manual)

        let window = makeWindow(scan: scan)
        defer { window.close() }

        drainMainRunLoop(for: 0.2)
        let checkingSize = fittingSize(scan: scan)

        scan.status = .results
        scan.progress = .finished

        drainMainRunLoop(for: 0.8)
        let resultsSize = fittingSize(scan: scan)

        XCTAssertEqual(resultsSize.width, checkingSize.width, accuracy: 0.5)
        XCTAssertEqual(resultsSize.height, checkingSize.height, accuracy: 0.5)
    }

    @MainActor
    private func makeWindow(scan: ScanStore) -> NSWindow {
        let rootView = ScanTransitionHarness()
            .environmentObject(scan)
            .frame(minWidth: 980, minHeight: 640)
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_125, height: 802),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.orderFront(nil)
        return window
    }

    @MainActor
    private func fittingSize(scan: ScanStore) -> CGSize {
        NSHostingView(rootView: ScanControlHarness().environmentObject(scan)).fittingSize
    }

    @MainActor
    private func drainMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

private struct ScanTransitionHarness: View {
    @EnvironmentObject private var scan: ScanStore
    @Namespace private var namespace

    var body: some View {
        NavigationSplitView {
            Color.clear
                .navigationSplitViewColumnWidth(240)
        } detail: {
            Group {
                if scan.status == .checking {
                    ProgressView()
                } else {
                    ScrollView {
                        LazyVStack {
                            ForEach(0..<32, id: \.self) { index in
                                Text("Update \(index)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ScanControl(namespace: namespace)
            }
        }
    }
}

private struct ScanControlHarness: View {
    @Namespace private var namespace

    var body: some View {
        ScanControl(namespace: namespace)
    }
}
