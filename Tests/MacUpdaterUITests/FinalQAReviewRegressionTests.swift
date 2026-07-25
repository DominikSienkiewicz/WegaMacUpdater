import AppKit
import MacUpdaterCore
import SwiftUI
import XCTest

@testable import WegaMacUpdater

final class FinalQAReviewRegressionTests: XCTestCase {
    func testConsentVerdictRefreshTracksRuntimeStateThroughReadCoordination() throws {
        let source = try projectSource(
            "Sources/MacUpdater/BackgroundUpdateConsentSettingsCard.swift")
        let readBoundarySource =
            (try? projectSource(
                "Sources/MacUpdater/BackgroundUpdateConsentMetadataReader.swift")) ?? source

        XCTAssertTrue(source.contains("NSWorkspace.didLaunchApplicationNotification"))
        XCTAssertTrue(source.contains("NSWorkspace.didTerminateApplicationNotification"))
        XCTAssertTrue(source.contains("Task.sleep(for:"))
        XCTAssertTrue(readBoundarySource.contains("OperationCoordinator.shared.withRead("))
    }

    @MainActor
    func testReduceMotionBinaryStreamKeepsLaneDataAcrossParentReconstruction() {
        let first = reflectedLaneSignature(BinaryStream(lanes: 4, baseSpeed: 42))
        let second = reflectedLaneSignature(BinaryStream(lanes: 4, baseSpeed: 42))

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            BinaryStreamLaneFactory.make(lanes: 4, baseSpeed: 42),
            BinaryStreamLaneFactory.make(lanes: 4, baseSpeed: 42)
        )
    }

    func testManualRowsExposeNativeKeyboardAndAccessibilityWiring() throws {
        let source = try projectSource("Sources/MacUpdater/UpdateViewSupport.swift")
        let manualRows = try sourceSection(
            source,
            startingAt: "struct ManualUpdateSection: View",
            endingAt: "struct ManualUpdateActionView: View"
        )

        XCTAssertTrue(manualRows.contains(".focusable(onInspect != nil)"))
        XCTAssertTrue(manualRows.contains(".onKeyPress(.return)"))
        XCTAssertTrue(manualRows.contains(".onKeyPress(.space)"))
        XCTAssertTrue(manualRows.contains(".accessibilityLabel("))
        XCTAssertFalse(manualRows.contains(".onTapGesture { onInspect?(item) }"))
    }

    func testManualRowReturnAndSpaceBothOpenTheInspector() {
        let item = ManualOutdatedApp(
            name: "Keyboard QA",
            path: URL(fileURLWithPath: "/Applications/Keyboard QA.app"),
            installedVersion: "1",
            availableVersion: "2",
            source: .sparkle
        )
        var inspected: [ManualOutdatedApp] = []

        XCTAssertTrue(ManualUpdateRowKeyboardBehavior.handle(
            .returnKey,
            item: item,
            onInspect: { inspected.append($0) }
        ))
        XCTAssertTrue(ManualUpdateRowKeyboardBehavior.handle(
            .spaceKey,
            item: item,
            onInspect: { inspected.append($0) }
        ))
        XCTAssertEqual(inspected, [item, item])
        XCTAssertFalse(ManualUpdateRowKeyboardBehavior.handle(
            .returnKey,
            item: item,
            onInspect: nil
        ))
    }

    func testConsentRefreshIdentityChangesForLifecycleAndWorkspaceEvents() {
        let initial = BackgroundConsentRefreshTaskID(
            configurationKey: "token|policy",
            lifecycleGeneration: 0,
            isActive: true
        )

        XCTAssertNotEqual(
            initial,
            BackgroundConsentRefreshTaskID(
                configurationKey: initial.configurationKey,
                lifecycleGeneration: 1,
                isActive: true
            )
        )
        XCTAssertNotEqual(
            initial,
            BackgroundConsentRefreshTaskID(
                configurationKey: initial.configurationKey,
                lifecycleGeneration: 0,
                isActive: false
            )
        )
    }

    @MainActor
    func testUninstallSheetCapsManyWarningsAtAccessibilityTextSize() {
        let targets = (0..<12).map { index in
            ApplicationInfo(
                path: URL(fileURLWithPath: "/Applications/QA Final \(index).app"),
                name: "QA Final \(index)",
                bundleIdentifier: "qa.final.\(index)",
                version: "1",
                installDate: nil,
                updateDate: nil,
                isManagedByBrew: true,
                caskToken: "qa-final-\(index)"
            )
        }
        let ambiguities = targets.map { target in
            AmbiguousBrewUninstall(
                bundleIdentifier: target.bundleIdentifier ?? "missing",
                appName: target.name,
                caskToken: target.caskToken ?? "missing",
                locations: [
                    "/Applications/\(target.name).app",
                    "/Users/qa/Applications/An intentionally long duplicate location/\(target.name).app",
                ]
            )
        }
        let hostingView = NSHostingView(
            rootView: UninstallDialog(
                targets: targets,
                ambiguities: ambiguities,
                onCancel: {},
                onConfirm: { _ in }
            )
            .environment(\.dynamicTypeSize, .accessibility5)
        )

        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.width, 480)
        XCTAssertLessThanOrEqual(
            hostingView.fittingSize.height,
            760,
            "The scrollable content must not push the persistent action buttons off screen"
        )
    }

    private func reflectedLaneSignature(_ stream: BinaryStream) -> String {
        guard let laneData = Mirror(reflecting: stream).children.first(where: {
            $0.label == "laneData"
        })?.value else {
            return "missing-lane-data"
        }
        return reflectedSignature(laneData)
    }

    private func reflectedSignature(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        guard !mirror.children.isEmpty else { return String(describing: value) }
        return mirror.children.map { child in
            "\(child.label ?? "_")=\(reflectedSignature(child.value))"
        }.joined(separator: "|")
    }

    private func projectSource(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func sourceSection(
        _ source: String,
        startingAt start: String,
        endingAt end: String
    ) throws -> Substring {
        let lowerBound = try XCTUnwrap(source.range(of: start)?.lowerBound)
        let upperBound = try XCTUnwrap(
            source.range(of: end, range: lowerBound..<source.endIndex)?.lowerBound
        )
        return source[lowerBound..<upperBound]
    }
}
