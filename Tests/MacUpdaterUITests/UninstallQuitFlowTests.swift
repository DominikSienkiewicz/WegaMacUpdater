import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

@Suite("Uninstall quit flow plan")
struct UninstallQuitFlowTests {
    private func app(_ name: String) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: "com.example.\(name.lowercased())",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )
    }

    @Test func cancelRemovesNothing() {
        let quiet = app("Quiet")
        let stubborn = app("Stubborn")
        let quit = UninstallQuitResult(stopped: [quiet.id], stillRunning: [stubborn])
        let plan = UninstallQuitFlow.plan(targets: [quiet, stubborn], quit: quit, choice: .cancel, forced: nil)
        #expect(plan == nil)
    }

    @Test func skipLeavesStubbornAppsOut() throws {
        let quiet = app("Quiet")
        let stubborn = app("Stubborn")
        let quit = UninstallQuitResult(stopped: [quiet.id], stillRunning: [stubborn])
        let plan = try #require(
            UninstallQuitFlow.plan(targets: [quiet, stubborn], quit: quit, choice: .skip, forced: nil)
        )
        #expect(plan.remove.map(\.id) == [quiet.id])
        #expect(plan.skipped == [stubborn.id: .skippedStillRunning])
    }

    @Test func forceQuitKeepsOnlyConfirmedStops() throws {
        let quiet = app("Quiet")
        let dies = app("Dies")
        let survives = app("Survives")
        let quit = UninstallQuitResult(stopped: [quiet.id], stillRunning: [dies, survives])
        let forced = UninstallQuitResult(stopped: [dies.id], stillRunning: [survives])
        let plan = try #require(UninstallQuitFlow.plan(
            targets: [quiet, dies, survives], quit: quit, choice: .forceQuit, forced: forced
        ))
        #expect(plan.remove.map(\.id) == [quiet.id, dies.id])
        #expect(plan.skipped == [survives.id: .skippedStillRunning])
    }

    @Test func ambiguousIsSkipped() throws {
        let quiet = app("Quiet")
        let twin = app("Twin")
        let quit = UninstallQuitResult(stopped: [quiet.id], ambiguous: [twin.id])
        let plan = try #require(
            UninstallQuitFlow.plan(targets: [quiet, twin], quit: quit, choice: nil, forced: nil)
        )
        #expect(plan.remove.map(\.id) == [quiet.id])
        #expect(plan.skipped == [twin.id: .skippedAmbiguousProcess])
    }

    @Test func stillRunningWithoutAChoiceRemovesNothing() {
        let stubborn = app("Stubborn")
        let quit = UninstallQuitResult(stillRunning: [stubborn])
        #expect(UninstallQuitFlow.plan(targets: [stubborn], quit: quit, choice: nil, forced: nil) == nil)
    }
}
