import AppKit
import MacUpdaterCore
import SwiftUI
import XCTest

@testable import WegaMacUpdater

/// The confirmation sheet's geometry, as the Uninstall sheet's is pinned: long content scrolls
/// while the risk line, the acknowledgement and the buttons stay on screen.
@MainActor
final class CleanupConfirmationSheetTests: XCTestCase {
    private static let home = URL(filePath: "/Users/cleanup-test", directoryHint: .isDirectory)

    func testLongProcessArgumentsScrollWhileTheButtonsStayPinned() {
        let hostingView = NSHostingView(
            rootView: sheet(for: Self.finding(status: .inUse(Self.longProcesses)))
                .environment(\.dynamicTypeSize, .accessibility5)
        )

        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.width, 480)
        XCTAssertLessThanOrEqual(
            hostingView.fittingSize.height, 760,
            "the process arguments must scroll, not push the confirmation buttons off screen"
        )
    }

    /// The remover's answer adds a second list; it scrolls inside the acknowledgement, so the
    /// toggle the confirm button waits for stays visible below it.
    func testAcknowledgementKeepsItsToggleVisibleUnderALongProcessList() {
        let hostingView = NSHostingView(
            rootView: CleanupInUseAcknowledgement(processes: Self.longProcesses, acknowledged: .constant(false))
                .frame(width: 472)
                .environment(\.dynamicTypeSize, .accessibility5)
        )

        XCTAssertLessThanOrEqual(
            hostingView.fittingSize.height, 260,
            "the acknowledged processes must scroll, not push the toggle and the buttons off screen"
        )
        XCTAssertGreaterThan(hostingView.fittingSize.height, 120)
    }

    func testShortConfirmationKeepsAUsableSize() {
        let hostingView = NSHostingView(rootView: sheet(for: Self.finding(status: .unused)))

        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.width, 480)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 300)
    }

    /// Twelve processes with forty long arguments each.
    private static let longProcesses = (0..<12).map { index in
        CleanupProcess(
            pid: Int32(800 + index), name: "node",
            executablePath: "/Users/cleanup-test/.local/share/claude/versions/2.1.318",
            arguments: ["node"] + (0..<40).map { "--option-\(index)-\($0)=/Users/cleanup-test/a/long/path/\($0)" }
        )
    }

    private func sheet(for finding: CleanupFinding) -> CleanupConfirmationSheet {
        CleanupConfirmationSheet(store: Self.store(), finding: finding, onClose: {})
    }

    private static func store() -> CleanupStore {
        let path = CleanupPathSnapshot(entries: ["/usr/bin"], ignoredEntries: [], shell: nil, capturedAt: nil, isApproximate: true)
        return CleanupStore(dependencies: CleanupStoreDependencies(
            home: home, coordinator: OperationCoordinator(),
            readPath: { .failed }, approximatePath: { path }, scan: { _ in throw CancellationError() },
            remove: { _ in .notRemovable }, loadReport: { nil }, saveReport: { _ in }, loadPath: { nil }, savePath: { _ in }
        ))
    }

    private static func finding(status: CleanupStatus) -> CleanupFinding {
        let url = home.appending(path: ".local/share/claude/versions/2.1.318", directoryHint: .notDirectory)
        return CleanupFinding(
            detector: .versionDirectories, tool: "claude", path: url, realpath: url,
            source: .nativeVersionDirectory(tool: "claude"), version: "2.1.318", size: 307_000_000,
            status: status, reason: .olderVersion(current: "2.1.325"), action: .trash([url]),
            risk: status == .unused ? .low : .high, bucket: status == .unused ? .safe : .needsDecision,
            identity: CleanupFileIdentity(device: 1, inode: 42)
        )
    }
}
