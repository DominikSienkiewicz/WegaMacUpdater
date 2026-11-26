import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Cleanup return context")
@MainActor
struct CleanupReturnStateTests {
    @Test func rebuildingTheDetailColumnRestoresTheDiskReviewAndItsReturnButton() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appending(path: "Sources/MacUpdater/DetailColumn.swift")
        let detail = try String(contentsOf: file, encoding: .utf8)
        let ownsReturnFilter = detail.contains("@State private var cleanupReturnFilter")
        #expect(!ownsReturnFilter, "A new window or language switch creates a fresh DetailColumn. Keep its return filter in the active review.")
        #expect(detail.contains("onNavigate(.updates(review.returnFilter))"))
    }

    @Test func theSharedReviewKeepsTheUpdatesCategoryUntilCleanupIsActuallyLeft() async throws {
        let store = ScanStore()
        let blocked = PostponeReason.insufficientDisk(required: 500, available: 100).updateBanner
        store.showBanner(blocked)
        #expect(store.beginCleanupSpaceReview(from: blocked))
        store.setCleanupReturnDestination(from: .updates(.security))
        let review = try #require(store.cleanupSpaceReview)
        #expect(review.returnFilter == .security && review.requiredBytes == 500)

        store.endCleanupSpaceReviewIfLeaving(from: .updates(.security), to: .cleanup)
        store.endCleanupSpaceReviewIfLeaving(from: .cleanup, to: .cleanup)
        store.endCleanupSpaceReviewIfLeaving(from: .updates(.cli), to: .inventory)
        await store.recheckCleanupSpace(review.id) { 450 }
        #expect(store.cleanupSpaceReview?.returnFilter == .security)
        #expect(store.cleanupSpaceReview?.missingBytes == 50)
        store.endCleanupSpaceReviewIfLeaving(from: .cleanup, to: .updates(review.returnFilter))
        #expect(store.cleanupSpaceReview == nil)

        store.showBanner(blocked)
        #expect(store.beginCleanupSpaceReview(from: blocked))
        store.setCleanupReturnDestination(from: .rollback)
        #expect(store.cleanupSpaceReview?.returnFilter == .all)
        store.clearDiskSpaceBanner()
        #expect(store.cleanupSpaceReview == nil)
    }
}
