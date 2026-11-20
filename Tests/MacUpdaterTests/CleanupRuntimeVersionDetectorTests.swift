import Foundation
import XCTest
@testable import MacUpdaterCore

final class CleanupRuntimeVersionDetectorTests: XCTestCase {
    private func findings(
        _ home: CleanupTempHome, projectFiles: [CleanupProjectFile] = [], processes: [CleanupProcess] = []
    ) -> [CleanupFinding] {
        CleanupRuntimeVersionDetector(
            fileSystem: LiveCleanupFileSystem(trash: { _ in }), home: home.home,
            inspector: FakeProcessInspector(processes: processes, bootTime: Date(timeIntervalSince1970: 0))
        ).findings(projectFiles: projectFiles)
    }

    private func projectFile(
        _ home: CleanupTempHome, _ relative: String, _ kind: CleanupProjectFileKind, _ text: String
    ) throws -> CleanupProjectFile {
        CleanupProjectFile(url: try home.file(relative, text: text), kind: kind, text: text)
    }

    private func finding(at install: URL, in findings: [CleanupFinding]) throws -> CleanupFinding {
        try XCTUnwrap(findings.first { $0.path.path == install.path }, "no finding for \(install.lastPathComponent)")
    }

    private func status(of install: URL, in findings: [CleanupFinding]) -> CleanupStatus? {
        findings.first { $0.path.path == install.path }?.status
    }

    private func pyproject(requiresPython range: String) -> String {
        "[project]\nname = \"app\"\nrequires-python = \"\(range)\"\n"
    }

    /// Brief case 7: uv's `~/.local/bin/python3` resolves into 3.15.2; nothing needs 3.12.12.
    func testUnreferencedUvPythonIsACandidateWithItsCommand() throws {
        let home = try CleanupTempHome()
        let current = try home.directory(".local/share/uv/python/cpython-3.15.2-macos-aarch64-none")
        let interpreter = try home.file(
            ".local/share/uv/python/cpython-3.15.2-macos-aarch64-none/bin/python3.15", size: 4096, executable: true
        )
        let link = try home.symlink(".local/bin/python3", to: interpreter.path)
        let old = try home.directory(".local/share/uv/python/cpython-3.12.12-macos-aarch64-none")
        try home.file(".local/share/uv/python/cpython-3.12.12-macos-aarch64-none/bin/python3.12", size: 4096, executable: true)

        let found = findings(home)

        XCTAssertEqual(found.count, 2)
        let kept = try finding(at: current, in: found)
        XCTAssertEqual(kept.status, .pinned(by: [link.path]))
        XCTAssertEqual(kept.reason, .requiredByProjects)
        XCTAssertEqual(kept.bucket, .excluded)
        let candidate = try finding(at: old, in: found)
        XCTAssertEqual(candidate.detector, .runtimeVersions)
        XCTAssertEqual(candidate.tool, "python")
        XCTAssertEqual(candidate.version, "3.12.12")
        XCTAssertEqual(candidate.source, .versionManager(.uv))
        XCTAssertEqual(candidate.status, .unused)
        XCTAssertEqual(candidate.reason, .notRequiredByProjects)
        XCTAssertEqual(candidate.action, .command("uv python uninstall 3.12.12"))
        XCTAssertEqual(candidate.risk, .medium)
        XCTAssertEqual(candidate.bucket, .needsDecision)
        XCTAssertEqual(candidate.realpath?.path, old.path)
        XCTAssertGreaterThan(candidate.size ?? 0, 0)
        XCTAssertEqual(candidate.identity, try LiveCleanupFileSystem(trash: { _ in }).entry(at: old)?.identity)
    }

    /// A pin names only the components it gives; every source is listed once, sorted.
    func testExactPinProtectsEveryMatchingPatch() throws {
        let home = try CleanupTempHome()
        let firstPatch = try home.directory(".pyenv/versions/3.12.1")
        let laterPatch = try home.directory(".pyenv/versions/3.12.12")
        let otherMinor = try home.directory(".pyenv/versions/3.11.4")
        let pin = try projectFile(home, "Dev/app/.python-version", .pythonVersion, "3.12\n")
        let toolVersions = try projectFile(home, "Dev/api/.tool-versions", .toolVersions, "python 3.12.12\n")

        let found = findings(home, projectFiles: [pin, toolVersions, pin])

        XCTAssertEqual(status(of: firstPatch, in: found), .pinned(by: [pin.url.path]))
        XCTAssertEqual(status(of: laterPatch, in: found), .pinned(by: [toolVersions.url.path, pin.url.path]))
        XCTAssertEqual(status(of: otherMinor, in: found), .unused)
    }

    func testRangeProtectsOnlyTheSoleSatisfyingInstall() throws {
        let sole = try CleanupTempHome()
        let older = try sole.directory(".pyenv/versions/3.12.8")
        let newer = try sole.directory(".pyenv/versions/3.15.1")
        let soleProject = try projectFile(sole, "Dev/app/pyproject.toml", .pyprojectToml, pyproject(requiresPython: ">=3.13"))

        let soleFound = findings(sole, projectFiles: [soleProject])

        XCTAssertEqual(status(of: newer, in: soleFound), .pinned(by: [soleProject.url.path]))
        XCTAssertEqual(status(of: older, in: soleFound), .unused)

        let shared = try CleanupTempHome()
        let uvInstall = try shared.directory(".local/share/uv/python/cpython-3.14.2-macos-aarch64-none")
        let pyenvInstall = try shared.directory(".pyenv/versions/3.15.1")
        let sharedProject = try projectFile(shared, "Dev/app/pyproject.toml", .pyprojectToml, pyproject(requiresPython: ">=3.13"))

        let sharedFound = findings(shared, projectFiles: [sharedProject])

        XCTAssertEqual(status(of: uvInstall, in: sharedFound), .unused, "3.15.1 under pyenv satisfies the range too")
        XCTAssertEqual(status(of: pyenvInstall, in: sharedFound), .unused, "3.14.2 under uv satisfies the range too")
    }

    /// `requires-python` reads `>3.9` as PEP 440 (3.9.18 satisfies it); `engines.node` reads `>18`
    /// as an npm x-range (18.5.0 does not).
    func testRangeGrammarFollowsTheTool() throws {
        let home = try CleanupTempHome()
        let python = try home.directory(".pyenv/versions/3.9.18")
        let node18 = try home.directory(".nvm/versions/node/v18.5.0")
        let node19 = try home.directory(".nvm/versions/node/v19.1.0")
        let pythonProject = try projectFile(home, "Dev/app/pyproject.toml", .pyprojectToml, pyproject(requiresPython: ">3.9"))
        let nodeProject = try projectFile(home, "Dev/web/package.json", .packageJson, #"{"engines": {"node": ">18"}}"#)

        let found = findings(home, projectFiles: [pythonProject, nodeProject])

        XCTAssertEqual(status(of: python, in: found), .pinned(by: [pythonProject.url.path]))
        XCTAssertEqual(status(of: node19, in: found), .pinned(by: [nodeProject.url.path]))
        XCTAssertEqual(status(of: node18, in: found), .unused)
    }

    /// Review Focus 2: an alias resolves at install time, so it keeps the newest of each manager.
    func testAliasProtectsTheNewestPerManager() throws {
        let home = try CleanupTempHome()
        let fnmOlder = try home.directory(".local/share/fnm/node-versions/v20.1.0")
        let fnmNewest = try home.directory(".local/share/fnm/node-versions/v22.3.0")
        let nvmOlder = try home.directory(".nvm/versions/node/v9.11.2")
        let nvmNewest = try home.directory(".nvm/versions/node/v16.0.0")
        let nvmrc = try projectFile(home, "Dev/web/.nvmrc", .nvmrc, "lts/*\n")

        let found = findings(home, projectFiles: [nvmrc])

        XCTAssertEqual(status(of: fnmNewest, in: found), .pinned(by: [nvmrc.url.path]))
        XCTAssertEqual(status(of: nvmNewest, in: found), .pinned(by: [nvmrc.url.path]))
        XCTAssertEqual(status(of: fnmOlder, in: found), .unused)
        XCTAssertEqual(status(of: nvmOlder, in: found), .unused)
        XCTAssertEqual(try finding(at: fnmOlder, in: found).action, .command("fnm uninstall 20.1.0"))
    }

    /// pyenv-virtualenv keeps an env inside its base interpreter (`versions/3.11.4/envs/myenv`) and
    /// links `versions/myenv` to it; `pyenv uninstall 3.11.4` would delete the env with it.
    func testVirtualenvAliasPinProtectsItsBaseInterpreter() throws {
        let home = try CleanupTempHome()
        let base = try home.directory(".pyenv/versions/3.11.4")
        let env = try home.directory(".pyenv/versions/3.11.4/envs/myenv")
        try home.symlink(".pyenv/versions/myenv", to: env.path)
        let newer = try home.directory(".pyenv/versions/3.12.1")
        let global = try home.file(".pyenv/version", text: "myenv\n")
        let pin = try projectFile(home, "Dev/app/.python-version", .pythonVersion, "myenv\n")

        let found = findings(home, projectFiles: [pin])

        XCTAssertEqual(found.count, 2, "the alias is not an install of its own")
        XCTAssertEqual(status(of: base, in: found), .pinned(by: [global.path, pin.url.path]))
        XCTAssertEqual(status(of: newer, in: found), .unused)
    }

    /// A custom nvm alias in `.nvmrc` names nothing installed; like a built-in alias it keeps the
    /// newest of each manager. A pin naming an installed version still protects only that one.
    func testPinNamingNothingInstalledProtectsTheNewest() throws {
        let home = try CleanupTempHome()
        let olderNode = try home.directory(".nvm/versions/node/v18.20.0")
        let newestNode = try home.directory(".nvm/versions/node/v20.11.0")
        let pinnedJava = try home.directory(".sdkman/candidates/java/17.0.9-tem")
        let newestJava = try home.directory(".sdkman/candidates/java/21.0.2-tem")
        let nvmrc = try projectFile(home, "Dev/web/.nvmrc", .nvmrc, "my-project\n")
        let sdkmanrc = try projectFile(home, "Dev/api/.sdkmanrc", .sdkmanrc, "java=17.0.9-tem\n")

        let found = findings(home, projectFiles: [nvmrc, sdkmanrc])

        XCTAssertEqual(status(of: newestNode, in: found), .pinned(by: [nvmrc.url.path]))
        XCTAssertEqual(status(of: olderNode, in: found), .unused)
        XCTAssertEqual(status(of: pinnedJava, in: found), .pinned(by: [sdkmanrc.url.path]))
        XCTAssertEqual(status(of: newestJava, in: found), .unused)
    }

    /// Review Focus 2: a range no grammar can read must not leave every interpreter unpinned.
    func testGarbageRangeNeverUnpinsEverything() throws {
        let home = try CleanupTempHome()
        let pyenvOlder = try home.directory(".pyenv/versions/3.11.4")
        let pyenvNewest = try home.directory(".pyenv/versions/3.12.1")
        let uvOnly = try home.directory(".local/share/uv/python/cpython-3.10.14-macos-aarch64-none")
        let project = try projectFile(home, "Dev/app/pyproject.toml", .pyprojectToml, pyproject(requiresPython: "whatever"))

        let found = findings(home, projectFiles: [project])

        XCTAssertEqual(status(of: pyenvNewest, in: found), .pinned(by: [project.url.path]))
        XCTAssertEqual(status(of: uvOnly, in: found), .pinned(by: [project.url.path]))
        XCTAssertEqual(status(of: pyenvOlder, in: found), .unused)
    }

    /// Rustup channel names and pyenv's other distributions do not start with a version number,
    /// so they are not ordered: each counts as newest, and an unreadable default or an alias never
    /// offers one for removal on a guess. `pypy3.10-7.3.12` must not outrank 3.12.1 as "10".
    func testUnorderableVersionNamesCountAsNewest() throws {
        let home = try CleanupTempHome()
        let stable = try home.directory(".rustup/toolchains/stable-aarch64-apple-darwin")
        let nightly = try home.directory(".rustup/toolchains/nightly-aarch64-apple-darwin")
        let olderToolchain = try home.directory(".rustup/toolchains/1.79.0-aarch64-apple-darwin")
        let newerToolchain = try home.directory(".rustup/toolchains/1.85.0-aarch64-apple-darwin")
        let settings = try home.file(".rustup/settings.toml", size: 262_145)
        let pypy = try home.directory(".pyenv/versions/pypy3.10-7.3.12")
        let olderPython = try home.directory(".pyenv/versions/3.11.4")
        let newerPython = try home.directory(".pyenv/versions/3.12.1")
        let project = try projectFile(home, "Dev/app/pyproject.toml", .pyprojectToml, pyproject(requiresPython: "whatever"))

        let found = findings(home, projectFiles: [project])

        XCTAssertEqual(status(of: stable, in: found), .pinned(by: [settings.path]))
        XCTAssertEqual(status(of: nightly, in: found), .pinned(by: [settings.path]))
        XCTAssertEqual(status(of: newerToolchain, in: found), .pinned(by: [settings.path]))
        XCTAssertEqual(status(of: olderToolchain, in: found), .unused)
        XCTAssertEqual(status(of: pypy, in: found), .pinned(by: [project.url.path]))
        XCTAssertEqual(status(of: newerPython, in: found), .pinned(by: [project.url.path]))
        XCTAssertEqual(status(of: olderPython, in: found), .unused)
    }

    func testVenvBaseInterpreterIsPinned() throws {
        let home = try CleanupTempHome()
        let base = try home.directory(".pyenv/versions/3.11.4")
        try home.file(".pyenv/versions/3.11.4/bin/python3.11", size: 16, executable: true)
        let samePrefix = try home.directory(".pyenv/versions/3.11")
        let other = try home.directory(".pyenv/versions/3.12.1")
        let config = try projectFile(
            home, "Dev/app/.venv/pyvenv.cfg", .pyvenvCfg,
            "home = \(base.path)/bin\ninclude-system-site-packages = false\nversion = 3.11.4\n"
        )

        let found = findings(home, projectFiles: [config])

        XCTAssertEqual(status(of: base, in: found), .pinned(by: [config.url.path]))
        XCTAssertEqual(status(of: samePrefix, in: found), .unused, "3.11 is not a path component of 3.11.4")
        XCTAssertEqual(status(of: other, in: found), .unused)
    }

    /// A venv may name its base through the manager's link or through the physical folder.
    func testVenvHomeThroughALinkedManagerRootIsPinned() throws {
        let home = try CleanupTempHome()
        let physicalOld = try home.directory("Tools/pyenv/versions/3.11.4")
        let physicalNew = try home.directory("Tools/pyenv/versions/3.12.1")
        try home.symlink(".pyenv", to: home.url("Tools/pyenv").path)
        let logicalOld = home.url(".pyenv/versions/3.11.4")
        let logicalNew = home.url(".pyenv/versions/3.12.1")
        let viaLink = try projectFile(home, "Dev/a/.venv/pyvenv.cfg", .pyvenvCfg, "home = \(logicalOld.path)/bin\n")
        let viaFolder = try projectFile(home, "Dev/b/.venv/pyvenv.cfg", .pyvenvCfg, "home = \(physicalNew.path)/bin\n")

        let found = findings(home, projectFiles: [viaLink, viaFolder])

        XCTAssertEqual(status(of: logicalOld, in: found), .pinned(by: [viaLink.url.path]))
        XCTAssertEqual(status(of: logicalNew, in: found), .pinned(by: [viaFolder.url.path]))
        XCTAssertEqual(try finding(at: logicalOld, in: found).realpath?.path, physicalOld.path)
    }

    func testNoFindingEverOffersTrash() throws {
        let home = try CleanupTempHome()
        let layouts = [
            ".local/share/uv/python/cpython-3.12.4-macos-aarch64-none", ".pyenv/versions/3.11.9", ".pyenv/versions/3.12;rm",
            ".local/share/fnm/node-versions/v20.1.0", ".nvm/versions/node/v16.0.0", ".sdkman/candidates/java/21.0.2-tem",
            ".rustup/toolchains/stable-aarch64-apple-darwin", ".local/share/mise/installs/node/22.1.0",
            ".asdf/installs/python/3.10.1", ".volta/tools/image/node/20.9.0", "Library/pnpm/nodejs/19.0.0",
        ]
        for layout in layouts { try home.directory(layout) }
        let executable = try home.file(".pyenv/versions/3.11.9/bin/python3.11", size: 16, executable: true)
        let running = CleanupProcess(pid: 42, name: "python3.11", executablePath: executable.path, arguments: [])
        let nvmrc = try projectFile(home, "Dev/web/.nvmrc", .nvmrc, "16\n")

        let found = findings(home, projectFiles: [nvmrc], processes: [running])

        XCTAssertEqual(found.count, layouts.count)
        XCTAssertTrue(found.contains { if case .pinned = $0.status { true } else { false } })
        XCTAssertTrue(found.contains { if case .inUse = $0.status { true } else { false } })
        XCTAssertTrue(found.contains { $0.status == .unused })
        for finding in found {
            switch finding.action {
            case .command, .instruction: break
            case .trash, .trashBatch, .brew, .uninstallApp, .none: XCTFail("\(finding.path.lastPathComponent) offers \(finding.action)")
            }
        }
        XCTAssertEqual(try finding(at: home.url(layouts[2]), in: found).action, .instruction(.removeWithCreatingTool))
        XCTAssertEqual(try finding(at: home.url(layouts[9]), in: found).action, .instruction(.removeWithCreatingTool))
    }

    func testRunningInterpreterIsInUse() throws {
        let home = try CleanupTempHome()
        let running = try home.directory(".pyenv/versions/3.10.0")
        let executable = try home.file(".pyenv/versions/3.10.0/bin/python3.10", size: 16, executable: true)
        let idle = try home.directory(".pyenv/versions/3.9.0")
        let process = CleanupProcess(pid: 4242, name: "python3.10", executablePath: executable.path, arguments: [])

        let found = findings(home, processes: [process])

        let inUse = try finding(at: running, in: found)
        XCTAssertEqual(inUse.status, .inUse([process]))
        XCTAssertEqual(inUse.reason, .notRequiredByProjects)
        XCTAssertEqual(inUse.bucket, .needsDecision)
        XCTAssertEqual(inUse.action, .command("pyenv uninstall 3.10.0"))
        XCTAssertEqual(status(of: idle, in: found), .unused)
    }
}
