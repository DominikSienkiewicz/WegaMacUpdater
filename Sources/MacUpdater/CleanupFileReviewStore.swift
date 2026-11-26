import Foundation
import MacUpdaterCore

enum CleanupFileRequest: Sendable {
    case installers(URL, OldInstallerAge)
    case xcode
}

enum ReviewedCleanupFile: Identifiable, Sendable {
    case installer(OldInstaller, OldInstallerScan)
    case xcode(XcodeCleanupItem)

    var id: URL {
        switch self {
        case let .installer(item, scan): scan.directory.appending(component: item.name, directoryHint: .notDirectory)
        case .xcode(let item): item.url
        }
    }

    var name: String {
        switch self {
        case .installer(let item, _): item.name
        case .xcode(let item): item.name
        }
    }

    var bytes: Int64? {
        switch self {
        case .installer(let item, _): item.size
        case .xcode(let item): item.sizeBytes
        }
    }

    var modified: Date {
        switch self {
        case .installer(let item, _): item.modifiedAt
        case .xcode(let item): item.lastModified
        }
    }

    var canTrash: Bool {
        switch self {
        case .installer: true
        case .xcode(let item): item.kind == .derivedData && item.canTrash
        }
    }
}

enum CleanupFileOrder: Hashable {
    case largest, oldest

    func precedes(_ left: ReviewedCleanupFile, _ right: ReviewedCleanupFile) -> Bool {
        switch self {
        case .largest where left.bytes != right.bytes: return (left.bytes ?? -1) > (right.bytes ?? -1)
        case .oldest where left.modified != right.modified: return left.modified < right.modified
        default: return left.id.path < right.id.path
        }
    }
}

@MainActor
final class CleanupFileReviewStore: ObservableObject {
    enum Phase { case idle, scanning, removing }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var files: [ReviewedCleanupFile]?
    @Published private(set) var error: String?
    @Published private(set) var movedName: String?
    @Published private(set) var scanCancelled = false
    @Published var allInstallerAges = false
    @Published private(set) var loadingRuntimes = false
    @Published private(set) var runtimeReport: SimulatorRuntimeReport?

    var installerFolder: URL? {
        guard case let .installers(folder, _)? = request else { return nil }
        return folder
    }

    private let installers = OldInstallerScanner()
    private let xcode = XcodeCleanup()
    private let loadRuntimes: @Sendable () async -> SimulatorRuntimeReport
    private let coordinator: OperationCoordinator
    private var request: CleanupFileRequest?
    private(set) var task: Task<Void, Never>?

    init(coordinator: OperationCoordinator = .shared,
         loadRuntimes: @escaping @Sendable () async -> SimulatorRuntimeReport = { await SimulatorRuntimeInventory().read() }) {
        self.coordinator = coordinator
        self.loadRuntimes = loadRuntimes
    }

    func refreshRuntimes() async {
        guard !loadingRuntimes else { return }
        loadingRuntimes = true
        runtimeReport = await loadRuntimes()
        loadingRuntimes = false
    }

    func scan(_ request: CleanupFileRequest) {
        guard phase == .idle else { return }
        self.request = request
        scanCancelled = false
        files = nil
        movedName = nil
        error = nil
        phase = .scanning
        task = Task {
            await read(request)
            endOperation()
        }
    }

    func cancelScan() {
        if phase == .scanning { task?.cancel() }
    }

    func moveToTrash(_ file: ReviewedCleanupFile) {
        guard phase == .idle, file.canTrash, let request, files?.contains(where: { $0.id == file.id }) == true else { return }
        phase = .removing
        movedName = nil
        error = nil
        task = Task {
            do {
                try await coordinator.withWrite(label: "cleanup.fileReview.trash") { [installers, xcode] in
                    switch file {
                    case let .installer(item, scan): try await installers.trash(item, from: scan)
                    case .xcode(let item): try await xcode.trash(item)
                    }
                }
                movedName = file.name
            } catch OperationCoordinator.LeaseError.externalInstallationPending {
                error = tr("Zakończ oczekującą instalację przed przeniesieniem pliku do Kosza.")
            } catch {
                self.error = tr("Nie udało się przenieść pozycji do Kosza. Sprawdź aktualny wynik skanu.")
            }
            files = nil
            phase = .scanning
            await read(request)
            endOperation()
        }
    }

    private func read(_ request: CleanupFileRequest) async {
        do {
            let result = try await coordinator.withRead(label: "cleanup.fileReview.scan") { [installers, xcode] in
                switch request {
                case let .installers(directory, age):
                    let scan = try await installers.scan(directory: directory, age: age)
                    return scan.installers.map { ReviewedCleanupFile.installer($0, scan) }
                case .xcode:
                    return try await xcode.scan().map(ReviewedCleanupFile.xcode)
                }
            }
            try Task.checkCancellation()
            files = result
        } catch is CancellationError {
            scanCancelled = true
        } catch {
            let message = tr("Nie udało się odczytać plików. Sprawdź dostęp do folderu i ponów skan.")
            self.error = [self.error, message].compactMap { $0 }.joined(separator: " ")
        }
    }

    private func endOperation() {
        phase = .idle
        task = nil
    }
}
