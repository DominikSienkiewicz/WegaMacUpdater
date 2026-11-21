import Foundation
import Testing
@testable import MacUpdaterCore

/// Owner decision 2026-11-21: while the settings `sudo` reads cannot be trusted, none of Wega's
/// own routes asks for the administrator password: the brew environment names no askpass and puts
/// no shim first, the shim lets `sudo` ask for nothing, and `mas`'s `sudo -v` is never started.
@Suite("Sudo prompt routes behind the gate")
struct SudoPromptRoutesGateTests {
    private let shimDirectory = "/Library/Application Support/Wega/sudo-shim"

    // MARK: The brew environment

    @Test func aClosedGateTakesTheAskpassAndTheShimOutOfTheEnvironment() {
        let open = [
            "PATH": "\(shimDirectory):\(HomebrewEnvironment.processPath)",
            "SUDO_ASKPASS": "/Library/Application Support/Wega/WegaAskpass",
            "HOME": "/Users/someone",
            "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        ]
        let closed = HomebrewEnvironment.withoutPasswordPrompts(open)
        #expect(closed["SUDO_ASKPASS"] == nil)
        #expect(closed["PATH"] == HomebrewEnvironment.processPath)
        #expect(closed["HOME"] == "/Users/someone")
        #expect(closed["HOMEBREW_NO_INSTALL_CLEANUP"] == "1")
    }

    // MARK: The sudo shim

    @Test func theShimLetsSudoAskForNothingWhileTheGateIsClosed() {
        #expect(HomebrewEnvironment.sudoShimArguments(forwarding: ["softwareupdate", "-i"], promptsAllowed: false)
                == ["-n", "softwareupdate", "-i"])
        #expect(HomebrewEnvironment.sudoShimArguments(forwarding: ["softwareupdate", "-i"], promptsAllowed: true)
                == ["-A", "softwareupdate", "-i"])
    }

    @Test func theShimNamesNoAskpassWhileTheGateIsClosed() {
        let overrides = HomebrewEnvironment.trustedSudoShimOverrides(promptsAllowed: false)
        #expect(overrides == ["PATH": HomebrewEnvironment.processPath])
    }

    // MARK: mas

    @Test func masNeverPrimesSudoWhileTheGateIsClosed() async throws {
        let runner = ScriptedMasRunner(responses: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "sudo: a terminal is required to read the password\nsudo: a password is required\n"),
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        ])
        let service = MasService(locator: BinaryLocator(masCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                                 runner: runner, passwordPromptsAllowed: { false })
        await #expect(throws: MasServiceError.passwordPromptHeld(arguments: ["upgrade", "123"])) {
            _ = try await service.upgrade(appStoreIDs: ["123"])
        }
        #expect(runner.requests.count == 1, "only the first mas upgrade; no sudo -v and no retry")
        #expect(!runner.requests.contains { $0.executableURL.path == "/usr/bin/sudo" })
    }

    @Test func aRunThatHoldsKeepsMasFromPrimingEvenWhenItsOwnReadIsSafe() async throws {
        let runner = ScriptedMasRunner(responses: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "sudo: a terminal is required to read the password\n"),
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        ])
        let service = MasService(locator: BinaryLocator(masCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                                 runner: runner, passwordPromptsAllowed: { true })
        await #expect(throws: MasServiceError.passwordPromptHeld(arguments: ["upgrade", "123"])) {
            _ = try await service.upgrade(appStoreIDs: ["123"], holdingPasswordPrompts: true)
        }
        #expect(!runner.requests.contains { $0.executableURL.path == "/usr/bin/sudo" })
    }

    @Test func masAsksTheGateOnlyWhenSudoWouldPrompt() async throws {
        let asked = Asked()
        let runner = ScriptedMasRunner(responses: [ProcessResult(exitCode: 0, stdout: "", stderr: "")])
        let service = MasService(locator: BinaryLocator(masCandidates: [URL(fileURLWithPath: "/usr/bin/true")]),
                                 runner: runner, passwordPromptsAllowed: { asked.mark(); return false })
        _ = try await service.upgrade(appStoreIDs: ["123"])
        #expect(!asked.value, "a mas upgrade that needs no sudo never asks")
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func mark() { lock.withLock { flag = true } }
}

private final class ScriptedMasRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [ProcessResult]
    private var made: [ProcessRequest] = []

    init(responses: [ProcessResult]) { self.responses = responses }

    var requests: [ProcessRequest] { lock.withLock { made } }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.withLock {
            made.append(request)
            return responses.isEmpty ? ProcessResult(exitCode: 0, stdout: "", stderr: "") : responses.removeFirst()
        }
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
