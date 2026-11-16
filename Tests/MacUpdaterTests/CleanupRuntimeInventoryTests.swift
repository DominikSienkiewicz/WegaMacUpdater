import Foundation
import XCTest
@testable import MacUpdaterCore

final class CleanupRuntimeInventoryTests: XCTestCase {
    private func inventory(_ home: CleanupTempHome) -> CleanupRuntimeInventory {
        CleanupRuntimeInventory(fileSystem: LiveCleanupFileSystem(trash: { _ in }), home: home.home)
    }

    func testInventoriesEveryManagerLayout() throws {
        let home = try CleanupTempHome()
        let layouts = [
            ".local/share/uv/python/cpython-3.12.4-macos-aarch64-none", ".pyenv/versions/3.11.9",
            ".local/share/fnm/node-versions/v20.1.0", ".fnm/node-versions/v18.2.0",
            ".nvm/versions/node/v16.0.0", ".sdkman/candidates/java/21.0.2-tem",
            ".rustup/toolchains/stable-aarch64-apple-darwin", ".local/share/mise/installs/NodeJS/22.1.0",
            ".asdf/installs/python/3.10.1", ".volta/tools/image/node/20.9.0", "Library/pnpm/nodejs/19.0.0",
        ]
        for layout in layouts { try home.directory(layout) }

        let found = inventory(home).installs()

        func install(
            _ manager: CleanupVersionManager, _ tool: String, _ version: String, _ path: String, _ removal: CleanupAction
        ) -> CleanupRuntimeInstall {
            CleanupRuntimeInstall(manager: manager, tool: tool, version: version, url: home.url(path), removal: removal)
        }
        let expected = [
            install(.uv, "python", "3.12.4", layouts[0], .command("uv python uninstall 3.12.4")),
            install(.pyenv, "python", "3.11.9", layouts[1], .command("pyenv uninstall 3.11.9")),
            install(.fnm, "node", "20.1.0", layouts[2], .command("fnm uninstall 20.1.0")),
            install(.fnm, "node", "18.2.0", layouts[3], .command("fnm uninstall 18.2.0")),
            install(.nvm, "node", "16.0.0", layouts[4], .command("nvm uninstall 16.0.0")),
            install(.sdkman, "java", "21.0.2-tem", layouts[5], .command("sdk uninstall java 21.0.2-tem")),
            install(.rustup, "rust", "stable-aarch64-apple-darwin", layouts[6],
                    .command("rustup toolchain uninstall stable-aarch64-apple-darwin")),
            install(.mise, "node", "22.1.0", layouts[7], .command("mise uninstall NodeJS@22.1.0")),
            install(.asdf, "python", "3.10.1", layouts[8], .command("asdf uninstall python 3.10.1")),
            install(.volta, "node", "20.9.0", layouts[9], .instruction(.removeWithCreatingTool)),
            install(.pnpmEnv, "node", "19.0.0", layouts[10], .command("pnpm env remove --global 19.0.0")),
        ]
        XCTAssertEqual(found.count, expected.count)
        for item in expected { XCTAssertTrue(found.contains(item), "missing \(item.manager) \(item.version)") }
    }

    func testSymlinkedAndDotEntriesAreSkipped() throws {
        let home = try CleanupTempHome()
        try home.directory(".pyenv/versions/3.11.9")
        try home.directory(".pyenv/versions/.hidden")
        try home.directory(".elsewhere/3.9.0")
        try home.symlink(".pyenv/versions/3.9.0", to: home.url(".elsewhere/3.9.0").path)
        try home.file(".pyenv/versions/notes.txt", text: "x")
        try home.directory(".local/share/mise/installs/node/20.0.0")
        try home.symlink(".local/share/mise/installs/node/latest", to: "20.0.0")

        let found = inventory(home).installs()

        XCTAssertEqual(found.map(\.version).sorted(), ["20.0.0", "3.11.9"])
    }

    func testUnsafeVersionNamesFallBackToInstruction() throws {
        let home = try CleanupTempHome()
        try home.directory(".pyenv/versions/3.12;rm")

        let found = inventory(home).installs()

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.version, "3.12;rm")
        XCTAssertEqual(found.first?.removal, .instruction(.removeWithCreatingTool))
    }

    func testDefaultsFromEachManagerSetting() throws {
        let home = try CleanupTempHome()
        let uvInstall = try home.directory(".local/share/uv/python/cpython-3.12.4-macos-aarch64-none")
        try home.file(".local/share/uv/python/cpython-3.12.4-macos-aarch64-none/bin/python3.12", text: "")
        let uvLink = try home.symlink(".local/bin/python3.12", to: uvInstall.appending(path: "bin/python3.12").path)
        try home.symlink(".local/bin/python3.99", to: home.url("missing").path)
        let fnmTarget = try home.directory(".local/share/fnm/node-versions/v20.1.0/installation")
        let fnmLink = try home.symlink(".local/share/fnm/aliases/default", to: fnmTarget.path)
        try home.file(".nvm/alias/default", text: "lts/*\n")
        let sdkTarget = try home.directory(".sdkman/candidates/java/21.0.2-tem")
        let sdkLink = try home.symlink(".sdkman/candidates/java/current", to: sdkTarget.path)
        try home.file(".rustup/settings.toml", text: """
        version = "12"
        default_toolchain = "stable-aarch64-apple-darwin"

        [overrides]
        "/Users/x/proj" = "nightly-aarch64-apple-darwin"
        """)
        try home.file(".volta/tools/user/platform.json", text: #"{"node":{"runtime":"20.9.0","npm":null}}"#)

        let found = inventory(home).defaults()

        func has(_ tool: String, _ spec: CleanupVersionSpec, _ source: URL) -> Bool {
            found.contains(CleanupRequirement(tool: tool, spec: spec, source: source))
        }
        XCTAssertTrue(has("python", .path(uvInstall.appending(path: "bin/python3.12").path), uvLink))
        XCTAssertTrue(has("node", .path(fnmTarget.path), fnmLink))
        XCTAssertTrue(has("node", .unresolvable("lts/*"), home.url(".nvm/alias/default")))
        XCTAssertTrue(has("java", .path(sdkTarget.path), sdkLink))
        let rustSettings = home.url(".rustup/settings.toml")
        XCTAssertTrue(has("rust", .pin("stable-aarch64-apple-darwin"), rustSettings))
        XCTAssertTrue(has("rust", .pin("nightly-aarch64-apple-darwin"), rustSettings))
        XCTAssertTrue(has("node", .pin("20.9.0"), home.url(".volta/tools/user/platform.json")))
        XCTAssertFalse(found.contains { $0.source.lastPathComponent == "python3.99" })
        XCTAssertEqual(found.count, 7)
    }

    func testMiseAndAsdfGlobalsReuseTheRequirementParser() throws {
        let home = try CleanupTempHome()
        try home.file(".config/mise/config.toml", text: "[tools]\nnodejs = \"20.1.0\"\n")
        try home.file(".tool-versions", text: "Python 3.11.9\n")
        try home.file(".pyenv/version", text: "3.11.9\n")

        let found = inventory(home).defaults()

        XCTAssertTrue(found.contains(CleanupRequirement(
            tool: "node", spec: .pin("20.1.0"), source: home.url(".config/mise/config.toml"))))
        XCTAssertTrue(found.contains(CleanupRequirement(
            tool: "python", spec: .pin("3.11.9"), source: home.url(".tool-versions"))))
        XCTAssertTrue(found.contains(CleanupRequirement(
            tool: "python", spec: .pin("3.11.9"), source: home.url(".pyenv/version"))))
    }

    func testPnpmCurrentLinkAndItsAbsence() throws {
        let home = try CleanupTempHome()
        let target = try home.directory("Library/pnpm/nodejs/19.0.0")
        XCTAssertEqual(inventory(home).defaults(), [
            CleanupRequirement(tool: "node", spec: .unresolvable("nodejs_current"),
                               source: home.url("Library/pnpm/nodejs_current")),
        ])

        let link = try home.symlink("Library/pnpm/nodejs_current", to: target.path)

        XCTAssertEqual(inventory(home).defaults(), [
            CleanupRequirement(tool: "node", spec: .path(target.path), source: link),
        ])
    }

    func testNoInstallsNoDefaults() throws {
        let home = try CleanupTempHome()

        XCTAssertEqual(inventory(home).installs(), [])
        XCTAssertEqual(inventory(home).defaults(), [])
    }
}
