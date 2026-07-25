import Foundation
import MacUpdaterCore

enum MigrationStatus {
    case ready
    case scanning
    case results
}

struct PendingForceTermination: Identifiable {
    let app: ApplicationInfo
    let target: RunningApplicationTarget

    var id: String { app.id }
}

/// App-owned state machine for migration. It deliberately lives above the localized
/// SwiftUI identity boundary, so changing language cannot erase an in-flight migration,
/// its consent dialog, results, or operation log.
@MainActor
final class MigrationStore: ObservableObject {
    @Published var status: MigrationStatus = .ready
    @Published var candidates: [ApplicationInfo] = []
    @Published var migrated: Set<String> = []
    @Published var migrating: String?
    @Published var confirmingApp: ApplicationInfo?
    @Published var logLines: [String] = []
    @Published var errorMessage: String?
    @Published var banner: BannerData?
    @Published var masCandidates: [(app: ApplicationInfo, masID: String)] = []
    @Published var npmBrewDuplicates: [NpmBrewDuplicate] = []
    @Published var duplicateConfirmation: DuplicateRemoval?
    @Published var duplicateBusyKey: String?
    @Published var pendingForceTermination: PendingForceTermination?

    func performRead(_ operation: @MainActor @Sendable () async -> Void) async {
        await OperationCoordinator.shared.withRead(label: "migration scan", operation: operation)
    }

    func performWrite(
        _ flow: UpgradeCoordinator.Flow,
        operation: @MainActor @Sendable () async -> Void
    ) async {
        await UpgradeCoordinator.shared.performWrite(flow, operation: operation)
    }
}
