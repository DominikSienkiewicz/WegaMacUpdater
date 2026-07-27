import Foundation
import Testing

@testable import MacUpdaterCore

/// ARCH-05a — wersje casków ustalane jednym zapytaniem, nie procesem per aplikacja.
///
/// `caskLatestVersion(token:)` uruchamia `brew info` osobno dla każdego tokenu, a skaner ręczny
/// wołał go raz na kandydata do adopcji. Maszyna z kilkunastoma aplikacjami spoza brew, które
/// Homebrew też pakuje, uruchamiała kilkanaście procesów, z których każdy czytał tę samą bazę
/// casków, żeby odpowiedzieć o jednym tokenie.
@Suite("ARCH-05a cask version batch")
struct CaskVersionBatchTests {

    private func service(stdout: String, exitCode: Int32 = 0, brewFound: Bool = true) -> BrewService {
        BrewService(
            locator: BinaryLocator(brewCandidates: brewFound ? [URL(fileURLWithPath: "/bin/sh")] : []),
            runner: StubProcessRunner(result: ProcessResult(exitCode: exitCode, stdout: stdout, stderr: ""))
        )
    }

    @Test func oneCallAnswersForEveryToken() async {
        let json = """
        {"casks":[{"token":"docker","version":"4.2"},{"token":"slack","version":"5.1"}]}
        """
        let versions = await service(stdout: json).caskLatestVersions(tokens: ["docker", "slack"])

        #expect(versions == ["docker": "4.2", "slack": "5.1"])
    }

    /// Token, którego Homebrew nie zna, po prostu nie ma w wyniku — wywołujący traktuje go tak
    /// samo jak wcześniej brak odpowiedzi.
    @Test func anUnknownTokenIsAbsentRatherThanWrong() async {
        let json = """
        {"casks":[{"token":"docker","version":"4.2"}]}
        """
        let versions = await service(stdout: json).caskLatestVersions(tokens: ["docker", "nieznany"])

        #expect(versions["docker"] == "4.2")
        #expect(versions["nieznany"] == nil)
    }

    /// Pusta lista nie może uruchomić procesu brew po nic.
    @Test func noTokensMeansNoCall() async {
        let versions = await service(stdout: "NIE POWINNO BYC CZYTANE", brewFound: false)
            .caskLatestVersions(tokens: [])

        #expect(versions.isEmpty)
    }

    @Test func aFailedCallYieldsAnEmptyMap() async {
        let versions = await service(stdout: "", exitCode: 1).caskLatestVersions(tokens: ["docker"])

        #expect(versions.isEmpty)
    }
}
