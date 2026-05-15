import XCTest
@testable import MacUpdaterCore

final class MasServiceSearchTests: XCTestCase {
    private func makeService(stdout: String, exitCode: Int32 = 0) -> MasService {
        let result = ProcessResult(exitCode: exitCode, stdout: stdout, stderr: "")
        let runner = StubProcessRunner(result: result)
        let locator = BinaryLocator(masCandidates: [URL(fileURLWithPath: "/usr/bin/true")])
        return MasService(locator: locator, runner: runner)
    }

    func testReturnsIDWhenExactNormalizedMatch() async throws {
        let stdout = "  324684580  Spotify - Music and Podcasts             1.2.13\n"
        let service = makeService(stdout: stdout)

        let id = try await service.search(name: "Spotify - Music and Podcasts")

        XCTAssertEqual(id, "324684580")
    }

    func testReturnsNilWhenNoExactMatch() async throws {
        let stdout = "  324684580  Spotify - Music and Podcasts             1.2.13\n"
        let service = makeService(stdout: stdout)

        let id = try await service.search(name: "Firefox")

        XCTAssertNil(id)
    }

    func testReturnsNilWhenMasExitsOne() async throws {
        // mas search exits 1 for "no results found"
        let service = makeService(stdout: "", exitCode: 1)

        let id = try await service.search(name: "AnyApp")

        XCTAssertNil(id)
    }

    func testThrowsCommandFailedWhenMasExitsUnexpected() async {
        // Exit codes other than 0 and 1 represent real errors
        let service = makeService(stdout: "", exitCode: 2)

        do {
            _ = try await service.search(name: "AnyApp")
            XCTFail("Expected commandFailed")
        } catch MasServiceError.commandFailed {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testReturnsNilWhenEmptyOutput() async throws {
        let service = makeService(stdout: "")

        let id = try await service.search(name: "AnyApp")

        XCTAssertNil(id)
    }

    func testThrowsWhenMasNotInstalled() async {
        let locator = BinaryLocator(masCandidates: [])
        let service = MasService(
            locator: locator,
            runner: StubProcessRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        )

        do {
            _ = try await service.search(name: "AnyApp")
            XCTFail("Expected masNotFound")
        } catch MasServiceError.masNotFound {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}
