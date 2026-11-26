import Foundation
import MacUpdaterCore
import XCTest
@testable import WegaMacUpdater

final class UninstallSourceFailureTests: XCTestCase {
    func testFailedCaskLookupBlocksUnknownAppsButGenuineAbsenceAllowsTrash() async {
        let app = ApplicationInfo(
            path: URL(filePath: "/Applications/Example.app"), name: "Example", bundleIdentifier: "org.example.app",
            version: "1", installDate: nil, updateDate: nil, isManagedByBrew: false
        )
        var storeApp = app
        storeApp.path = URL(filePath: "/Applications/Store.app")
        storeApp.isManagedByMas = true
        let apps = [app, storeApp]
        func scan(error: Error) async -> UninstallScan {
            await UninstallScan.collect(
                directories: [URL(filePath: "/Applications")], installedCasks: { throw error },
                scanApplications: { _, _ in apps }, protections: { _ in [:] }
            )
        }

        let failed = await scan(error: CocoaError(.fileReadUnknown))
        XCTAssertNotNil(failed.protections[app.id])
        XCTAssertNil(failed.protections[storeApp.id])

        let absent = await scan(error: BrewServiceError.brewNotFound)
        XCTAssertTrue(absent.protections.isEmpty)
        XCTAssertFalse(absent.scanFailed)
    }
}
