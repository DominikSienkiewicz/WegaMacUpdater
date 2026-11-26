import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Independent Xcode simulator inventory")
@MainActor
struct SimulatorRuntimeReviewStoreTests {
    @Test func runtimeRefreshDoesNotRunOrReplaceTheFileScan() async {
        let snapshot = SimulatorRuntimeReport(status: .loaded([]), xcodeApplication: nil)
        let store = CleanupFileReviewStore(loadRuntimes: { snapshot })
        #expect(store.runtimeReport == nil)
        #expect(store.files == nil)
        await store.refreshRuntimes()
        #expect(store.runtimeReport == snapshot)
        #expect(!store.loadingRuntimes)
        #expect(store.phase == .idle && store.files == nil && store.error == nil)
    }
}
