import XCTest
@testable import MacUpdaterCore

final class AskpassHelperTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wega-askpass-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testInstallWritesExecutableScript() throws {
        let url = try AskpassHelper.install(in: tempDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("#!"), "Missing shebang: \(contents.prefix(20))")
        XCTAssertTrue(contents.contains("osascript"), "Should call osascript for the dialog")

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attrs[.posixPermissions] as? NSNumber
        XCTAssertNotNil(permissions)
        // owner-executable bit (0o100)
        XCTAssertEqual((permissions!.intValue & 0o100), 0o100, "Script must be executable")
    }

    func testInstallIsIdempotent() throws {
        let first = try AskpassHelper.install(in: tempDir)
        let second = try AskpassHelper.install(in: tempDir)
        XCTAssertEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
}
