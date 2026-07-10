import XCTest
@testable import MacUpdaterCore

/// `caskArtifactProfiles` is what feeds `RollbackProtection` (M5), the "may need an admin
/// password" note (F2) and the background-update gate (F3) — three decisions about whether
/// it is safe to touch a user's machine. It shipped with nothing exercising it.
///
/// No brew is spawned: the process runner is stubbed, and the locator is pointed at a file
/// that merely has to exist and be executable.
final class BrewServiceArtifactProfilesTests: XCTestCase {
    private static let brewJSON = """
    {
      "casks": [
        {
          "token": "iterm2",
          "homepage": "https://iterm2.com/",
          "artifacts": [{ "app": ["iTerm.app"] }, { "zap": [{ "trash": ["~/Library/Caches/iterm2"] }] }]
        }
      ]
    }
    """

    private func service(exitCode: Int32 = 0, stdout: String = "", brewFound: Bool = true) -> BrewService {
        BrewService(
            locator: BinaryLocator(brewCandidates: brewFound ? [URL(fileURLWithPath: "/bin/sh")] : []),
            runner: StubProcessRunner(result: ProcessResult(exitCode: exitCode, stdout: stdout, stderr: ""))
        )
    }

    /// An empty token list must not spawn brew at all — the scan calls this on every pass.
    func testNoTokensReturnsNoProfilesWithoutRunningBrew() async throws {
        let profiles = try await service(brewFound: false).caskArtifactProfiles(tokens: [])
        XCTAssertTrue(profiles.isEmpty)
    }

    func testProfilesAreParsedFromBrewOutput() async throws {
        let profiles = try await service(stdout: Self.brewJSON).caskArtifactProfiles(tokens: ["iterm2"])

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.token, "iterm2")
        XCTAssertEqual(profiles.first?.homepage, "https://iterm2.com/")
        XCTAssertEqual(profiles.first?.artifactKinds, [.app, .zap])
    }

    /// A non-zero exit must throw rather than hand back an empty profile list — an empty
    /// list reads as "this cask installs nothing", which would make it look ineligible for
    /// rollback protection instead of unknown.
    func testNonZeroExitThrowsCommandFailed() async {
        do {
            _ = try await service(exitCode: 1, stdout: "").caskArtifactProfiles(tokens: ["iterm2"])
            XCTFail("expected a thrown error")
        } catch BrewServiceError.commandFailed(let arguments, _) {
            XCTAssertEqual(arguments, ["info", "--cask", "--json=v2", "iterm2"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// F4 leans on this: a missing brew is `brewNotFound`, never a generic failure.
    func testMissingBrewThrowsBrewNotFound() async {
        do {
            _ = try await service(brewFound: false).caskArtifactProfiles(tokens: ["iterm2"])
            XCTFail("expected a thrown error")
        } catch BrewServiceError.brewNotFound {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
