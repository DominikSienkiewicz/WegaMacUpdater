import Foundation
import MacUpdaterCore

struct UpdateDiskBudget: Equatable, Sendable {
    let required: Int64
    let available: Int64
    var shortfall: Int64 { max(0, max(0, required) - max(0, available)) }
}

extension BannerAction {
    var cleanupBudget: UpdateDiskBudget? {
        guard case .openCleanup(let budget) = self else { return nil }
        return budget
    }
}

struct CleanupSpaceReview: Equatable, Identifiable {
    enum Reading: Equatable {
        case atDeferral(available: Int64)
        case checking
        case measured(available: Int64)
        case unavailable
    }

    let id = UUID()
    let requiredBytes: Int64
    var returnFilter: UpdateFilter = .all
    var reading: Reading

    var missingBytes: Int64? {
        switch reading {
        case .atDeferral(let available), .measured(let available):
            UpdateDiskBudget(required: requiredBytes, available: available).shortfall
        case .checking, .unavailable:
            nil
        }
    }
}

extension ScanStore {
    func beginCleanupSpaceReview(from banner: BannerData) -> Bool {
        guard self.banner == banner, let budget = banner.action?.cleanupBudget else { return false }
        cleanupSpaceReview = CleanupSpaceReview(requiredBytes: budget.required, reading: .atDeferral(available: budget.available))
        dismissBanner()
        return true
    }

    func setCleanupReturnDestination(from source: SidebarSelection) {
        cleanupSpaceReview?.returnFilter = source.filter ?? .all
    }

    func endCleanupSpaceReviewIfLeaving(from previous: SidebarSelection, to destination: SidebarSelection) {
        if previous == .cleanup && destination != .cleanup { endCleanupSpaceReview() }
    }

    func endCleanupSpaceReview() {
        if cleanupSpaceReview != nil { cleanupSpaceReview = nil }
    }

    func recheckCleanupSpace(_ id: UUID, readAvailable: @MainActor () async -> Int64? = {
        await Task.detached(priority: .utility) { DiskResourceProbe.availableBytes() }.value
    }) async {
        guard let review = cleanupSpaceReview, review.id == id, review.reading != .checking else { return }
        cleanupSpaceReview?.reading = .checking
        let bytes = await readAvailable()
        guard cleanupSpaceReview?.id == id else { return }
        if let bytes, bytes >= 0 {
            cleanupSpaceReview?.reading = .measured(available: bytes)
        } else {
            cleanupSpaceReview?.reading = .unavailable
        }
    }
}
