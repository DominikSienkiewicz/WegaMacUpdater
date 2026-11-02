import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("A cask receipt ahead of the bundle cannot commit an unchanged build")
@MainActor
struct CaskBuildDriftVerificationTests {
    @Test(arguments: [
        ("0.4.16+1", "0.4.16,2"),
        ("1.2.3-beta", "1.2.3"),
    ])
    func unchangedBuildIsNotVerifiedOrCommitted(installed: String, offered: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cask-build-drift-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Applications/Example.app", isDirectory: true)
        try makeApp(at: appURL, version: installed)
        let store = UpdateOperationStore(rootDirectory: root.appendingPathComponent("operations"))
        let operation = store.begin(trigger: .adoption)
        operation.recordPlanned(tokens: ["example"], appPaths: ["example": appURL])
        let snapshots = CaskRollbackGuard.snapshot(
            tokens: ["example"], appPaths: ["example": appURL], operation: operation,
            dependencies: dependencies()
        )
        let snapshotURL = try #require(snapshots["example"])
        operation.recordInstalling()

        let verdict = await CaskRollbackGuard.verify(
            token: "example", snapshotURL: snapshotURL, validationURL: appURL,
            expecting: .init(teamID: "TEAM", bundleIdentifier: "com.example.drift", version: offered),
            operation: operation, dependencies: dependencies()
        )

        #expect(verdict == .notUpgraded)
        let item = try #require(store.operations().first?.items.first)
        #expect(item.phase == .aborted)
        #expect(!item.history.map(\.phase).contains(.verified))
        #expect(!item.history.map(\.phase).contains(.committed))
        #expect(UpdateOperationRecoveryPlan.bundleShortVersion(at: appURL) == installed)
    }

    private func makeApp(at appURL: URL, version: String) throws {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.example.drift", "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func dependencies() -> CaskRollbackGuard.Dependencies {
        CaskRollbackGuard.Dependencies(
            teamIDBeforeMutation: { _ in "TEAM" },
            teamIDAfterMutation: { _ in "TEAM" },
            recordTeamID: { _, teamID in .unchanged(teamID: teamID) },
            applyRollbackLedger: { _, _ in },
            clone: { source, destination in
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source, to: destination)
            },
            bundleIdentifier: { _ in "com.example.drift" },
            passesGatekeeper: { _ in true },
            restore: { _, _ in Issue.record("unchanged build must not trigger a rollback") },
            helperIsEnabled: { false },
            helperReplace: { _, _ in Issue.record("unchanged build must not invoke the helper") },
            removeItem: { _ in },
            smokeTestIsEnabled: { false },
            launchSmokeTest: { _ in
                Issue.record("unchanged build must not be launched")
                return .survived
            }
        )
    }
}
