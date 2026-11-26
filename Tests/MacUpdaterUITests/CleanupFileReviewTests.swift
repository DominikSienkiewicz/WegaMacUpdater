import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Optional file reviews in Cleanup") @MainActor
struct CleanupFileReviewTests {
    @Test func cleanupOffersInstallerAndXcodeReviewsInBothLanguages() throws {
        let view = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/MacUpdater/CleanupView.swift")
        let source = try String(contentsOf: view, encoding: .utf8)
        #expect(source.contains("CleanupFileReviewView("))
        #expect(Translations.en["Stare instalatory"] == "Old installers")
        #expect(Translations.en["Porządki po Xcode"] == "Xcode cleanup")
    }

    @Test func reviewMeasuresOnlyTheChosenFolderAndOrdersBySizeOrAge() async throws {
        let root = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
            .appending(component: "wega-installer-review-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appending(component: "Chosen", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        func installer(in folder: URL, name: String, bytes: Int, days: Int) throws {
            let url = folder.appending(component: name, directoryHint: .notDirectory)
            try Data(repeating: 1, count: bytes).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(Double(-days) * 86_400)],
                                                  ofItemAtPath: url.path)
        }
        try installer(in: selected, name: "Smaller.dmg", bytes: 2, days: 80)
        try installer(in: selected, name: "Larger.dmg", bytes: 8, days: 40)
        try installer(in: selected, name: "Recent.dmg", bytes: 1, days: 1)
        try installer(in: root, name: "Outside.dmg", bytes: 16, days: 100)

        let store = CleanupFileReviewStore(coordinator: OperationCoordinator())
        #expect(store.files == nil)
        store.scan(.installers(selected, .olderThan30Days))
        await store.task?.value
        #expect(store.error == nil)
        let files = try #require(store.files)
        #expect(files.sorted(by: CleanupFileOrder.largest.precedes).map(\.name) == ["Larger.dmg", "Smaller.dmg"])
        #expect(files.sorted(by: CleanupFileOrder.oldest.precedes).map(\.name) == ["Smaller.dmg", "Larger.dmg"])
        store.scan(.installers(selected, .all))
        await store.task?.value
        #expect(store.files?.count == 3)

        store.scan(.installers(root.appending(path: "Missing"), .all))
        await store.task?.value
        #expect(store.files == nil && store.error != nil && store.phase == .idle)
    }

    @Test func inFlightReviewAndResultsSurviveSwitchingCleanupPages() async throws {
        let folder = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
            .appending(component: "wega-review-switch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1]).write(to: folder.appending(component: "Package.dmg"))

        let path = CleanupPathSnapshot(entries: [], ignoredEntries: [], shell: nil, capturedAt: nil, isApproximate: true)
        let cleanup = CleanupStore(dependencies: CleanupStoreDependencies(
            home: folder, coordinator: OperationCoordinator(), readPath: { .failed }, approximatePath: { path },
            scan: { _ in throw CancellationError() }, remove: { _ in .notRemovable }, loadReport: { nil },
            saveReport: { _ in }, loadPath: { nil }, savePath: { _ in }, loadKeptCopies: { [:] }
        ))
        cleanup.filePage = .installers
        cleanup.installerReview.scan(.installers(folder, .all))
        cleanup.filePage = .xcode
        #expect(cleanup.xcodeReview.files == nil)
        await cleanup.installerReview.task?.value
        cleanup.filePage = .installers
        #expect(cleanup.installerReview.files?.map(\.name) == ["Package.dmg"])
        #expect(cleanup.installerReview.installerFolder == folder)
    }
}
