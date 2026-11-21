import AppKit
import MacUpdaterCore
import SwiftUI
import XCTest

@testable import WegaMacUpdater

/// UXP-13 — while a scan runs in place over rows, the list header's grouping menu gives way to
/// „Zaznaczanie wróci, gdy skan się skończy.”. That note is wider than the menu it replaces, so
/// it must give way itself — truncate — rather than push the scope bar into its menu fallback,
/// overlap it, or make the header wider than it is without a scan; and it must not be cut where
/// the header has room for it.
///
/// UXP-21 — at the minimum detail column the idle header used to be wider than its 360 pt (the
/// labelled grouping picker alone took 191.5 pt in Polish). `UpdateGroupingMenu` now shortens to
/// fit, so the idle header is held to the column and the note to "no wider than idle".
@MainActor
final class ListHeaderScanNoteLayoutTests: XCTestCase {
    /// The header's width at the minimum detail column (420 pt, as `UpdateBandViewTests`), up to
    /// a wide window where the scope bar turns segmented.
    private static let headerWidths: [CGFloat] = [420, 480, 520, 700, 960, 1200].map { $0 - 2 * WegaLayout.selectionColumnInset }

    private let counts = UpdateScopeCounts(apps: 128, cli: 46, security: 12)

    func testTheScanNoteNeverPushesTheScopeBar() {
        for width in Self.headerWidths {
            for language in [AppLanguage.pl, .en] {
                let idle = withLanguage(language) { frames(scanning: false, width: width) }
                let scanning = withLanguage(language) { frames(scanning: true, width: width) }
                let note = withLanguage(language) {
                    NSHostingView(rootView: Text(tr("Zaznaczanie wróci, gdy skan się skończy.")).font(.wega(.subheadline)).fixedSize())
                        .fittingSize.width
                }
                guard let idleScope = idle["scope"], let idleSlot = idle["slot"],
                      let scope = scanning["scope"], let slot = scanning["slot"] else {
                    return XCTFail("\(language), \(width) pt: the header's parts were not measured")
                }
                let context = "\(language), \(width) pt"
                XCTAssertEqual(scope.width, idleScope.width, accuracy: 0.5, "\(context): the note changed the scope bar's width")
                XCTAssertLessThanOrEqual(scope.maxX, slot.minX + 0.5, "\(context): the note overlaps the scope bar")
                XCTAssertLessThanOrEqual(slot.maxX, max(width, idleSlot.maxX) + 0.5, "\(context): the note widened the header")
                if scope.maxX + 2 * WegaLayout.checkboxSpacing + note <= width {
                    XCTAssertGreaterThanOrEqual(slot.width, note - 0.5, "\(context): the note is cut although it fits")
                }
            }
        }
    }

    /// At the 420 pt detail column the idle header used to be 415 of 360 pt wide; no width may
    /// overflow now, including those where the scope bar turns segmented.
    func testTheIdleHeaderFitsEveryColumn() {
        for width in Self.headerWidths {
            for language in [AppLanguage.pl, .en] {
                let idle = withLanguage(language) { frames(scanning: false, width: width) }
                let context = "\(language), \(width) pt"
                guard let scope = idle["scope"], let slot = idle["slot"] else { return XCTFail("\(context): not measured") }
                XCTAssertLessThanOrEqual(scope.maxX, slot.minX + 0.5, "\(context): the grouping menu overlaps the scope bar")
                XCTAssertLessThanOrEqual(slot.maxX, width + 0.5, "\(context): the header is wider than its column")
            }
        }
    }

    /// The composition above is `UpdateView.listHeader`'s; this keeps the two the same.
    func testTheMeasuredHeaderIsTheRealOne() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let start = try XCTUnwrap(view.range(of: "private var listHeader: some View"))
        let header = view[start.upperBound...].prefix(1200)
        XCTAssertTrue(header.contains("HStack(spacing: WegaLayout.checkboxSpacing) {"))
        XCTAssertTrue(header.contains("scopeBar\n            Spacer(minLength: 0)\n            groupingControl"))
        XCTAssertTrue(view.contains("ListHeaderGroupingSlot(showsScanNote: ScanSelectionGate.coversList(isRefreshing: scan.isRefreshing, showsRows: showsRows))"))
        XCTAssertTrue(view.contains("UpdateGroupingMenu(selection: $grouping)"))
    }

    // MARK: - Helpers

    private func header(scanning: Bool) -> some View {
        HStack(spacing: WegaLayout.checkboxSpacing) {
            SelectionCheckbox(state: .none, accessibilityLabel: "x", toggle: {})
            UpdateScopeBar(filter: .all, counts: counts) { _ in }
                .measured("scope")
            Spacer(minLength: 0)
            ListHeaderGroupingSlot(showsScanNote: scanning) {
                UpdateGroupingMenu(selection: .constant(.default))
            }
            .measured("slot")
        }
    }

    private func frames(scanning: Bool, width: CGFloat) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        let host = NSHostingView(rootView: header(scanning: scanning)
            .frame(width: width, alignment: .leading)
            .coordinateSpace(.named(HeaderFrameKey.space))
            .onPreferenceChange(HeaderFrameKey.self) { frames = $0 })
        host.frame = CGRect(x: 0, y: 0, width: width, height: 40)
        host.layoutSubtreeIfNeeded()
        return frames
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private struct HeaderFrameKey: PreferenceKey {
    static let space = "listHeader"
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func measured(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: HeaderFrameKey.self, value: [name: proxy.frame(in: .named(HeaderFrameKey.space))])
        })
    }
}
