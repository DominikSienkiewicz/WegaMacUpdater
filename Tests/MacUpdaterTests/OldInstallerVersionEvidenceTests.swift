import Foundation
import XCTest
import WegaHelperKit
@testable import MacUpdaterCore

final class OldInstallerVersionEvidenceTests: XCTestCase {
    private func xml(path: String = "./Applications/Fixture.app", id: String = "test.fixture", version: String = "2.1") -> String {
        """
        <pkg-info identifier="test.component" version="2.1" install-location="/">
          <bundle-version><bundle id="\(id)" path="\(path)" CFBundleShortVersionString="\(version)"/></bundle-version>
        </pkg-info>
        """
    }

    func testHintRequiresMatchingIdentifierVersionAndPublisherOnTheInstalledApp() throws {
        let home = try CleanupTempHome()
        let root = try home.directory("Applications")
        let plist = ["CFBundleIdentifier": "test.fixture", "CFBundleShortVersionString": "2.1"]
        let path = home.url("Applications/Fixture.app/Contents/Info.plist")
        try home.directory("Applications/Fixture.app/Contents")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: path)
        func version(_ xml: String, appTeam: String = "ABCDEFGHIJ") -> String? {
            OldInstallerVersionEvidence.confirmedVersion(packageInfo: xml, packageTeam: "ABCDEFGHIJ",
                applications: root, matchesPublisher: { _, _, expected in appTeam == expected })
        }
        XCTAssertEqual(version(xml()), "2.1")
        XCTAssertNil(version(xml(version: "2.0")))
        XCTAssertNil(version(xml(id: "test.sibling")))
        XCTAssertNil(version(xml(), appTeam: "OTHERTEAM1"))
        for escaped in ["./Applications/../Private/File.app", "/Users/Test/Private.app", "./Applications/link/Fixture.app"] {
            XCTAssertNil(version(xml(path: escaped)))
        }
        XCTAssertNil(version("<!DOCTYPE pkg-info [<!ENTITY one 'abc'>]>" + xml()))
        XCTAssertNil(version(String(repeating: "a", count: 100_000)))
        XCTAssertNil(OldInstallerVersionEvidence.leafTeam(in: "Status: signed by (ABCDEFGHIJ)"))
        XCTAssertEqual(OldInstallerVersionEvidence.leafTeam(in: """
            Status: signed by a developer certificate issued by Apple for distribution
              1. Developer ID Installer: Fixture (ABCDEFGHIJ)
            """), "ABCDEFGHIJ")
        try FileManager.default.moveItem(at: root.appending(component: "Fixture.app"), to: home.url("elsewhere"))
        try home.symlink("Applications/Fixture.app", to: home.url("elsewhere").path)
        XCTAssertNil(version(xml()))
    }

    @MainActor func testOnlyPackageInfoIsReadFromSyntheticFlatPackage() async throws {
        let home = try CleanupTempHome()
        try home.file("PackageInfo", text: xml())
        try home.file("Payload", text: "synthetic payload")
        let path = home.url("fixture.pkg")
        let create = try BoundedProcess.run(URL(fileURLWithPath: "/usr/bin/bsdtar"),
            arguments: ["--format", "xar", "-cf", path.path, "-C", home.home.path, "PackageInfo", "Payload"], timeouts: .quick)
        XCTAssertEqual(create.exitCode, 0)
        XCTAssertEqual(OldInstallerVersionEvidence.packageInfo(in: path), xml())
        let scanner = OldInstallerScanner(now: { .now }, trash: { _ in XCTFail("No deletion during scan") }, installedVersion: { pinned in
            OldInstallerVersionEvidence.packageInfo(in: pinned)?.contains("CFBundleShortVersionString=\"2.1\"") == true ? "2.1" : nil
        })
        let scan = try await scanner.scan(directory: home.home, age: .all)
        XCTAssertEqual(scan.installers.map(\.installedVersion), ["2.1"])
    }
}
