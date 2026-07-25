import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Authorization component resolver")
struct AuthorizationComponentResolverTests {
    @Test func everyResolutionRevalidatesBothCompiledExecutables() throws {
        let directory = try makeHelpersDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var validations: [(String, String)] = []
        let resolver = AuthorizationComponentResolver(
            helpersDirectory: directory,
            verifyCode: { url, signingID in
                validations.append((url.lastPathComponent, signingID))
            }
        )

        let first = try resolver.resolveAndVerify()
        let second = try resolver.resolveAndVerify()

        #expect(first == second)
        #expect(first.askpassExecutable.lastPathComponent == "WegaAskpass")
        #expect(first.sudoShimDirectory == directory.appendingPathComponent("sudo-shim"))
        #expect(validations.map(\.0) == [
            "WegaAskpass", "sudo", "WegaAskpass", "sudo"
        ])
        #expect(validations.map(\.1) == [
            WegaHelper.askpassSigningID,
            WegaHelper.sudoShimSigningID,
            WegaHelper.askpassSigningID,
            WegaHelper.sudoShimSigningID
        ])
    }

    @Test func aFailedCodeHashVerificationFailsClosed() throws {
        let directory = try makeHelpersDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = AuthorizationComponentResolver(
            helpersDirectory: directory,
            verifyCode: { url, _ in
                if url.lastPathComponent == "sudo" {
                    throw StubError.invalidSignature
                }
            }
        )

        #expect(throws: StubError.invalidSignature) {
            try resolver.resolveAndVerify()
        }
    }

    @Test func authorizationEnvironmentDropsUntrustedInheritedVariables() {
        let result = AuthorizationEnvironment.sanitized(
            inherited: [
                "HOME": "/Users/tester",
                "LANG": "pl_PL.UTF-8",
                "LC_CTYPE": "UTF-8",
                "WEGA_SUDO_REAL": "/tmp/attacker",
                "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
                "BASH_ENV": "/tmp/profile",
                "PATH": "/tmp/attacker"
            ],
            overrides: [
                "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
                "SUDO_ASKPASS": "/Applications/Wega.app/Contents/Helpers/WegaAskpass",
                "WEGA_SUDO_REAL": "/tmp/still-attacker"
            ]
        )

        #expect(result["HOME"] == "/Users/tester")
        #expect(result["LANG"] == "pl_PL.UTF-8")
        #expect(result["LC_CTYPE"] == "UTF-8")
        #expect(result["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin")
        #expect(result["SUDO_ASKPASS"]?.hasSuffix("WegaAskpass") == true)
        #expect(result["WEGA_SUDO_REAL"] == nil)
        #expect(result["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(result["BASH_ENV"] == nil)
    }

    private func makeHelpersDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-authorization-components-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sudoDirectory = directory.appendingPathComponent("sudo-shim")
        try FileManager.default.createDirectory(
            at: sudoDirectory,
            withIntermediateDirectories: true
        )
        for executable in [
            directory.appendingPathComponent("WegaAskpass"),
            sudoDirectory.appendingPathComponent("sudo")
        ] {
            let name = executable.lastPathComponent
            try Data(name.utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: executable.path
            )
        }
        return directory
    }

    private enum StubError: Error, Equatable {
        case invalidSignature
    }
}
