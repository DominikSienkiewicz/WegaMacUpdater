import Foundation
import MacUpdaterCore
import Testing
import WegaTestSupport

@testable import WegaMacUpdater

private struct StartupDiskOnly: MountTableReading {
    func mountPoints() -> [String] { ["/"] }
}

@Suite("Cleanup project roots settings model")
@MainActor
struct CleanupProjectRootsSettingsTests {
    private let home = URL(filePath: "/Users/wega", directoryHint: .isDirectory)

    private func model(_ defaults: UserDefaults) -> CleanupProjectRootsSettingsModel {
        CleanupProjectRootsSettingsModel(
            defaults: defaults, home: home,
            protectedLocations: ProtectedLocationGuard(home: home, mounts: StartupDiskOnly())
        )
    }

    @Test func testModelAddsRemovesAndReportsRejection() {
        let (defaults, teardown) = TestDefaults.isolated("cleanup-project-roots-model")
        defer { teardown() }
        let model = model(defaults)
        #expect(model.roots.map(\.path) == ["/Users/wega/Dev"])

        model.add(URL(filePath: "/Users/wega/code", directoryHint: .isDirectory))
        #expect(model.roots.map(\.path) == ["/Users/wega/Dev", "/Users/wega/code"])
        #expect(model.rejection == nil)

        model.add(URL(filePath: "/Users/wega/Documents/code", directoryHint: .isDirectory))
        #expect(model.rejection == .protectedLocation)
        #expect(model.roots.count == 2)

        model.add(URL(filePath: "/Users/wega/code", directoryHint: .isDirectory))
        #expect(model.rejection == .alreadyListed)

        model.remove(URL(filePath: "/Users/wega/Dev", directoryHint: .isDirectory))
        #expect(model.roots.map(\.path) == ["/Users/wega/code"])
        #expect(model.rejection == nil)
        #expect(self.model(defaults).roots.map(\.path) == ["/Users/wega/code"])
    }
}
