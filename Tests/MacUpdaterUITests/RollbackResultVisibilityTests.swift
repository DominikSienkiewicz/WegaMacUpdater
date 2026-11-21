import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Rollback result visibility")
@MainActor
struct RollbackResultVisibilityTests {
    @Test func undoWithoutASnapshotRaisesABanner() async throws {
        let token = "undo-missing-\(UUID().uuidString)"
        let root = try makeScanStoreRuntimeTemporaryDirectory("undo-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        try makeScanStoreRuntimeApp(at: app, bundleIdentifier: "example.\(token)", version: "2.0", payload: "after")
        let operation = try makeScanStoreRuntimeUndoOperation(token: token, appURL: app, copySnapshot: false)
        defer { UpdateOperationStore.shared.removeOperation(id: operation.operationID) }
        let harness = makeScanStoreRuntimeHarness(runner: ScanStoreRuntimeProcessRunner { _ in
            ProcessResult(exitCode: 0, stdout: "{}", stderr: "") })

        await harness.store.undoUpdate(operation.undoable)

        #expect(harness.store.banner?.variant == .danger)
        #expect(harness.store.banner?.message
                == trf("Nie mogę cofnąć %@: kopia sprzed aktualizacji już nie istnieje.", token))
    }

    @Test func undoWhenTheAppIsGoneRaisesABanner() async throws {
        let token = "undo-gone-\(UUID().uuidString)"
        let root = try makeScanStoreRuntimeTemporaryDirectory("undo-gone")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        try makeScanStoreRuntimeApp(at: app, bundleIdentifier: "example.\(token)", version: "1.0", payload: "before")
        let operation = try makeScanStoreRuntimeUndoOperation(token: token, appURL: app, copySnapshot: true)
        defer { UpdateOperationStore.shared.removeOperation(id: operation.operationID) }
        try FileManager.default.removeItem(at: app)
        let harness = makeScanStoreRuntimeHarness(runner: ScanStoreRuntimeProcessRunner { _ in
            ProcessResult(exitCode: 0, stdout: "{}", stderr: "") })

        await harness.store.undoUpdate(operation.undoable)

        #expect(harness.store.banner?.variant == .danger)
        #expect(harness.store.banner?.message
                == trf("Nie mogę cofnąć %@: aplikacji nie ma już w tym miejscu.", token))
    }

    @Test func undoSuccessStaysUntilClosed() {
        let data = BannerData(variant: .success, title: "t", message: "m", autoDismiss: false)
        #expect(!BannerDismissal.isSelfDismissing(data))
    }

    @Test func theRollbackScreenShowsBannersAndAnHonestEmptyState() throws {
        let view = try source("Sources/MacUpdater/RollbackView.swift")
        #expect(view.contains("ScanBannerHost("))
        #expect(view.contains("Dla aktualizacji aplikacji z Homebrew, które to obsługują"))
        #expect(!view.contains("Po każdej aktualizacji Wega trzyma kopię"))
    }

    /// M12 — „Pokaż w logach” on an Undo banner opened Logs unfiltered, while the same banner
    /// on Updates opened it on errors only. Both screens now go through one helper.
    @Test func everyBannerOpensTheLogsOnErrorsOnly() throws {
        let detail = try source("Sources/MacUpdater/DetailColumn.swift")
        let helper = try #require(detail.range(of: "private func navigate(fromBanner tab: SidebarTab)"),
                                  "M12: one helper decides what a banner's navigation does")
        #expect(detail[helper.upperBound...].prefix(200).contains("logsInitialFilter = .errorsOnly"))
        #expect(detail.contains("RollbackView(onNavigate: navigate(fromBanner:))"),
                "M12: the Undo screen's banners use the same helper")
        #expect(detail.contains("onNavigate:    navigate(fromBanner:)"),
                "the Updates screen's banners use it too")
        #expect(detail.components(separatedBy: "logsInitialFilter = .errorsOnly").count == 2,
                "the filter is set in one place only")
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
