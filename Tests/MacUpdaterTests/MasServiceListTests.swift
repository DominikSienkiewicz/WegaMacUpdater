import XCTest
@testable import MacUpdaterCore

final class MasServiceListTests: XCTestCase {
    func testListParsesOutput() async throws {
        let fakeResult = ProcessResult(exitCode: 0, stdout: "1569813296  MyApp (1.0)", stderr: "")
        let runner = StubProcessRunner(result: fakeResult)
        // Use /usr/bin/true as a stand-in — runner is stubbed so the binary is never executed
        let locator = BinaryLocator(masCandidates: [URL(fileURLWithPath: "/usr/bin/true")])
        let service = MasService(locator: locator, runner: runner)

        let apps = try await service.list()

        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].appStoreID, "1569813296")
        XCTAssertEqual(apps[0].name, "MyApp")
        XCTAssertEqual(apps[0].version, "1.0")
    }

    func testListThrowsWhenMasMissing() async {
        // Empty candidates → locateMas() returns nil → masNotFound
        let locator = BinaryLocator(masCandidates: [])
        let service = MasService(
            locator: locator,
            runner: StubProcessRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        )

        do {
            _ = try await service.list()
            XCTFail("Expected masNotFound")
        } catch MasServiceError.masNotFound {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}
