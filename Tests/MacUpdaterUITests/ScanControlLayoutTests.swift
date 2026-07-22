import Foundation
import XCTest

/// Runs the real SwiftUI app scene because an `NSHostingController` does not install scene-level
/// toolbar items in the same way as `WindowGroup`. The debug-only scenario reproduces the exact
/// checking-to-results transition recorded in the attached crash.
final class ScanControlLayoutTests: XCTestCase {
    func testCheckingToResultsTransitionDoesNotCrashWindowLayout() throws {
        let appURL = try XCTUnwrap(
            Bundle(for: Self.self).bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("WegaMacUpdater")
        )
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: appURL.path))

        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("WegaMacUpdater-layout-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        let process = Process()
        process.executableURL = appURL
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CFFIXED_USER_HOME": temporaryHome.path,
            "HOME": temporaryHome.path,
            "WEGA_LAYOUT_REGRESSION_TEST": "1"
        ]) { _, testValue in testValue }

        let terminated = expectation(description: "layout regression app terminated")
        process.terminationHandler = { _ in terminated.fulfill() }
        try process.run()

        let result = XCTWaiter.wait(for: [terminated], timeout: 10)
        if result != .completed, process.isRunning {
            process.terminate()
        }

        XCTAssertEqual(result, .completed, "The layout regression app did not finish within 10 seconds")
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
