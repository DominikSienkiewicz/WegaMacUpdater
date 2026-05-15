import XCTest
@testable import MacUpdaterCore

final class ApplicationScannerMasTests: XCTestCase {
    var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func makeApp(named name: String, withReceipt: Bool) throws -> URL {
        let appURL = tmpDir.appendingPathComponent("\(name).app")
        let contentsURL = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        // Write a minimal Info.plist so Bundle can read the name
        let plist: [String: Any] = [
            "CFBundleName": name,
            "CFBundleIdentifier": "com.test.\(name.lowercased())",
            "CFBundleShortVersionString": "1.0"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        if withReceipt {
            let receiptDir = contentsURL
                .appendingPathComponent("_MASReceipt", isDirectory: true)
            try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
            try Data().write(to: receiptDir.appendingPathComponent("receipt"))
        }
        return appURL
    }

    func testMasReceiptDetected() throws {
        try makeApp(named: "MasApp", withReceipt: true)
        try makeApp(named: "RegularApp", withReceipt: false)

        let scanner = ApplicationScanner()
        let apps = try scanner.scanApplications(in: tmpDir)

        let masApp = try XCTUnwrap(apps.first { $0.name == "MasApp" })
        let regularApp = try XCTUnwrap(apps.first { $0.name == "RegularApp" })

        XCTAssertTrue(masApp.isManagedByMas)
        XCTAssertFalse(masApp.isManagedByBrew)
        XCTAssertNil(masApp.caskToken)

        XCTAssertFalse(regularApp.isManagedByMas)
    }

    func testMasPriorityOverCaskCandidate() throws {
        try makeApp(named: "Firefox", withReceipt: true)

        let scanner = ApplicationScanner()
        let casks = [BrewCask(token: "firefox", name: ["Firefox"])]
        let apps = try scanner.scanApplications(in: tmpDir, installedCasks: [], availableCasks: casks)

        let app = try XCTUnwrap(apps.first { $0.name == "Firefox" })
        XCTAssertTrue(app.isManagedByMas)
        XCTAssertFalse(app.isManagedByBrew)
        XCTAssertNil(app.caskToken)
    }
}
