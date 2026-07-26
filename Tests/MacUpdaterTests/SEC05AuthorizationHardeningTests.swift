import Foundation
import Testing
@testable import MacUpdaterCore
// SEC-10: SudoLocalTransactionalWriter / enableShellCommand moved to WegaHelperKit.
@testable import WegaHelperKit

@Suite("SEC-05 authorization hardening")
struct SEC05AuthorizationHardeningTests {
    @Test func legacyAskpassInstallerMakesItsDirectoryPrivate() throws {
        let directory = temporaryDirectory(named: "askpass")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        _ = try AskpassHelper.install(in: directory)

        #expect(try permissions(of: directory) == 0o700)
    }

    @Test func legacySudoInstallerMakesItsDirectoryPrivate() throws {
        let directory = temporaryDirectory(named: "sudo")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        _ = try SudoShim.install(in: directory)

        #expect(try permissions(of: directory) == 0o700)
    }

    @Test func legacyInstallersAtomicallyRepairModifiedScriptBytesBeforeReuse() throws {
        let askpassDirectory = temporaryDirectory(named: "askpass-repair")
        let sudoDirectory = temporaryDirectory(named: "sudo-repair")
        defer {
            try? FileManager.default.removeItem(at: askpassDirectory)
            try? FileManager.default.removeItem(at: sudoDirectory)
        }

        let askpass = try AskpassHelper.install(in: askpassDirectory)
        let expectedAskpass = try Data(contentsOf: askpass)
        try Data("malicious askpass".utf8).write(to: askpass)

        let installedSudoDirectory = try SudoShim.install(in: sudoDirectory)
        let sudo = installedSudoDirectory.appendingPathComponent(SudoShim.scriptName)
        let expectedSudo = try Data(contentsOf: sudo)
        try Data("malicious sudo".utf8).write(to: sudo)

        _ = try AskpassHelper.install(in: askpassDirectory)
        _ = try SudoShim.install(in: sudoDirectory)

        #expect(try Data(contentsOf: askpass) == expectedAskpass)
        #expect(try Data(contentsOf: sudo) == expectedSudo)
        #expect(try permissions(of: askpassDirectory) == 0o700)
        #expect(try permissions(of: sudoDirectory) == 0o700)
    }

    @Test func productionWiringUsesVerifiedBundleExecutablesInsteadOfUserScripts() throws {
        let source = try contents(of: "Sources/MacUpdaterCore/HomebrewEnvironment.swift")
        let infoView = try contents(of: "Sources/MacUpdater/InfoView.swift")

        #expect(source.contains("AuthorizationComponentResolver"))
        #expect(source.contains("resolveAndVerify()"))
        #expect(!source.contains("AskpassHelper.installInApplicationSupport"))
        #expect(!source.contains("SudoShim.installInApplicationSupport"))
        #expect(!infoView.contains("TouchIDSudoConfigurator.enableShellCommand"))
    }

    @Test func brewAndMasDoNotReinheritTheUnsanitizedParentEnvironment() throws {
        let sources = try contents(of: "Sources/MacUpdaterCore/BrewService.swift")
            + contents(of: "Sources/MacUpdaterCore/MasService.swift")

        #expect(sources.contains("inheritParentEnvironment: false"))
        #expect(!sources.contains("WEGA_SUDO_REAL"))
    }

    @Test func packageBuildEmbedsAndSignsCompiledAuthorizationComponents() throws {
        let package = try contents(of: "Package.swift")
        let buildScript = try contents(of: "scripts/build-pkg.sh")

        #expect(package.contains("WegaAskpass"))
        #expect(package.contains("WegaSudoShim"))
        #expect(buildScript.contains("Contents/Helpers"))
        #expect(buildScript.contains("WegaAskpass"))
        #expect(buildScript.contains("WegaSudoShim"))
        #expect(buildScript.contains("com.wega.WegaMacUpdater.askpass"))
        #expect(buildScript.contains("com.wega.WegaMacUpdater.sudo-shim"))
    }

    @Test func sudoComponentNeverUsesTheInheritedTestEscapeHatch() throws {
        let source = try contents(of: "Sources/WegaSudoShim/main.swift")

        #expect(!source.contains("WEGA_SUDO_REAL"))
        #expect(source.contains("/usr/bin/sudo"))
        #expect(source.contains("AuthorizationEnvironment.sanitized"))
    }

    @Test func pamWriterIsTransactionalAndManualDetectionIgnoresComments() throws {
        let source = try contents(of: "Sources/MacUpdaterCore/TouchIDSudoConfigurator.swift")
            + contents(of: "Sources/MacUpdaterCore/SudoLocalTransactionalWriter.swift")

        #expect(source.contains("SudoLocalTransactionalWriter"))
        #expect(source.contains("writeAtomically"))
        #expect(source.contains("verifyReadback"))
        #expect(source.contains("rollback"))
        #expect(source.contains(#"^[[:space:]]*auth[[:space:]]+sufficient"#))
    }

    @Test func transactionalTerminalFallbackIsValidShellSyntax() throws {
        let command = TouchIDSudoConfigurator.manualEnableTerminalCommand
        let prefix = "sudo /bin/sh -c '"
        let suffix = "'"
        #expect(command.hasPrefix(prefix))
        #expect(command.hasSuffix(suffix))
        let script = String(command.dropFirst(prefix.count).dropLast(suffix.count))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    private func temporaryDirectory(named suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-sec-05-\(suffix)-\(UUID().uuidString)")
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: packageRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
