import Foundation
import MacUpdaterCore
import Testing
import WegaTestSupport

@testable import WegaMacUpdater

@Suite("Scan directories settings model coverage")
@MainActor
struct ScanDirectoryModelCoverageTests {
    @Test func mutationsRoundTripThroughTheInjectedDefaults() throws {
        let (defaults, teardown) = TestDefaults.isolated("scan-directories-settings")
        defer { teardown() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-scan-settings-\(UUID().uuidString)", isDirectory: true)
        let included = root.appendingPathComponent("Included", isDirectory: true)
        let excluded = root.appendingPathComponent("Excluded", isDirectory: true)
        try FileManager.default.createDirectory(at: included, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = ScanDirectoriesSettingsModel(defaults: defaults)
        #expect(model.userDirectories.isEmpty)
        #expect(model.exclusions.isEmpty)

        model.addUserDirectory(included)
        model.addExclusion(excluded)
        model.setRecursionDepth(2)

        let reloaded = ScanDirectoriesSettingsModel(defaults: defaults)
        #expect(reloaded.userDirectories.map(\.lastPathComponent) == ["Included"])
        #expect(reloaded.exclusions.map(\.lastPathComponent) == ["Excluded"])
        #expect(reloaded.recursionDepth == 2)

        reloaded.removeUserDirectory(included)
        reloaded.removeExclusion(excluded)
        #expect(reloaded.userDirectories.isEmpty)
        #expect(reloaded.exclusions.isEmpty)
    }

    @Test func reloadObservesExternalChangesAndDepthIsClampedByTheStore() throws {
        let (defaults, teardown) = TestDefaults.isolated("scan-directories-reload")
        defer { teardown() }

        let model = ScanDirectoriesSettingsModel(defaults: defaults)
        ScanConfigurationStore.setRecursionDepth(Int.max, in: defaults)
        model.reload()

        #expect(model.recursionDepth == ScanConfiguration.maximumRecursionDepth)

        ScanConfigurationStore.setRecursionDepth(-1, in: defaults)
        model.reload()
        #expect(model.recursionDepth == 0)
    }
}
