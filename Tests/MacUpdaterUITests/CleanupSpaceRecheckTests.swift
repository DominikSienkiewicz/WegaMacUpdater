import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite @MainActor
struct CleanupSpaceRecheckTests {
    @Test func rechecksCapacityAgainstTheBlockedBudgetWithoutChangingTheQueue() async throws {
        let store = ScanStore()
        let selection: Set<String> = ["c:example"]
        store.selected = selection
        let banner = PostponeReason.insufficientDisk(required: 5_000_000_000, available: 2_000_000_000).updateBanner
        store.showBanner(banner)
        #expect(store.beginCleanupSpaceReview(from: banner))
        let request = try #require(store.cleanupSpaceReview)
        #expect(request.requiredBytes == 5_000_000_000)
        #expect(request.reading == .atDeferral(available: 2_000_000_000))
        #expect(store.banner == nil)

        await store.recheckCleanupSpace(request.id) { 4_000_000_000 }
        #expect(store.cleanupSpaceReview?.reading == .measured(available: 4_000_000_000))
        #expect(store.cleanupSpaceReview?.missingBytes == 1_000_000_000)
        await store.recheckCleanupSpace(request.id) { 5_000_000_000 }
        #expect(store.cleanupSpaceReview?.missingBytes == 0)
        await store.recheckCleanupSpace(request.id) { nil }
        #expect(store.cleanupSpaceReview?.reading == .unavailable)
        #expect(store.cleanupSpaceReview?.missingBytes == nil)
        #expect(store.cleanupSpaceReview?.id == request.id)
        #expect(store.selected == selection)
        #expect(!store.updating)
    }

    @Test func aReplacedOrClosedReviewDiscardsItsOutstandingReading() async throws {
        let store = ScanStore()
        let first = PostponeReason.insufficientDisk(required: 100, available: 50).updateBanner
        let second = PostponeReason.insufficientDisk(required: 300, available: 100).updateBanner
        store.showBanner(first)
        #expect(store.beginCleanupSpaceReview(from: first))
        let firstID = try #require(store.cleanupSpaceReview?.id)

        await store.recheckCleanupSpace(firstID) {
            store.clearDiskSpaceBanner()
            store.showBanner(second)
            #expect(!store.beginCleanupSpaceReview(from: first))
            #expect(store.beginCleanupSpaceReview(from: second))
            return 10_000
        }
        let replacement = try #require(store.cleanupSpaceReview)
        #expect(replacement.id != firstID)
        #expect(replacement.requiredBytes == 300)
        #expect(replacement.reading == .atDeferral(available: 100))
        await store.recheckCleanupSpace(replacement.id) {
            store.endCleanupSpaceReview()
            return 10_000
        }
        #expect(store.cleanupSpaceReview == nil)
    }
}
