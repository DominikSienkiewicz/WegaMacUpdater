import Foundation
import Testing

@testable import MacUpdaterCore

/// ARCH-04 — jeden przebieg `brew info` odpowiada na wszystkie trzy pytania o cask.
///
/// `caskInstallationInfo`, `caskArtifactProfiles` i `caskDownloadInfo` uruchamiają identyczne
/// `brew info --cask --json=v2 <tokeny>` i różnią się wyłącznie parserem tego samego `stdout`.
/// Czytnik metadanych zgody wołał wszystkie trzy równolegle z tą samą listą tokenów, więc jeden
/// skan uruchamiał ten sam proces trzykrotnie.
@Suite("ARCH-04 single cask info query")
struct SingleCaskInfoQueryTests {

    private static let json = """
    {"casks":[{"token":"iterm2","version":"3.5","homepage":"https://iterm2.com/",
      "artifacts":[{"app":["iTerm.app"]}],
      "url":"https://iterm2.com/i.zip","sha256":"abc123"}]}
    """

    private func service(stdout: String = json, exitCode: Int32 = 0, brewFound: Bool = true) -> BrewService {
        BrewService(
            locator: BinaryLocator(brewCandidates: brewFound ? [URL(fileURLWithPath: "/bin/sh")] : []),
            runner: StubProcessRunner(result: ProcessResult(exitCode: exitCode, stdout: stdout, stderr: ""))
        )
    }

    @Test func oneRunFillsAllThreeViews() async throws {
        let info = try await service().caskInfo(tokens: ["iterm2"])

        #expect(info.profiles.first?.token == "iterm2")
        #expect(info.downloads.isEmpty == false)
        #expect(info.installations.isEmpty == false)
    }

    /// Pusta lista tokenów nie może uruchomić brew po nic — skan woła to przy każdym przebiegu.
    @Test func noTokensMeansNoProcess() async throws {
        let info = try await service(brewFound: false).caskInfo(tokens: [])

        #expect(info == BrewCaskInfo())
    }

    /// Widoki pochodzą z tego samego `stdout`, więc nie mogą opisywać różnych stanów świata —
    /// to była realna możliwość, gdy każdy z nich pytał brew osobno.
    @Test func theThreeViewsDescribeTheSameRun() async throws {
        let info = try await service().caskInfo(tokens: ["iterm2"])

        #expect(info.profiles.first?.token == info.installations.first?.token)
    }
}
