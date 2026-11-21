import Foundation
import WegaHelperKit
import XCTest

/// Z14, review RC3 and R1: the helper serves only from a bundle every entry of which belongs to root
/// and nobody else can write, so a .pkg that installs one group-writable folder — a builder's umask
/// is enough — or that Installer may relocate into a copy the user owns would leave every genuine
/// install refused. `scripts/verify-pkg-payload.sh` reads the built package's `PackageInfo` and `Bom`
/// and fails the build; `build-pkg.sh` runs it on the package it just made.
///
/// XCTest, not Swift Testing: it runs `pkgbuild` and waits on it, which must not block the
/// cooperative pool the timing-sensitive suites share (CONTRIBUTING, "Test framework").
final class PkgPayloadVerificationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wega-pkg-payload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testASoundPayloadPasses() throws {
        let pkg = try buildPackage()

        let result = try verify(pkg)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Contents/MacOS/WegaPrivilegedHelper"), result.output)
    }

    func testAFolderTheGroupCanWriteFails() throws {
        let pkg = try buildPackage { payload in
            try self.chmod(payload.appendingPathComponent("Applications/WegaMacUpdater.app/Contents/MacOS"), 0o775)
        }

        let result = try verify(pkg)

        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("Contents/MacOS"), result.output)
    }

    func testAFileOthersCanWriteFails() throws {
        let plist = "Applications/WegaMacUpdater.app/Contents/Library/LaunchDaemons/\(WegaHelper.plistName)"
        let pkg = try buildPackage { payload in try self.chmod(payload.appendingPathComponent(plist), 0o646) }

        let result = try verify(pkg)

        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains(WegaHelper.plistName), result.output)
    }

    func testAMissingEntryFails() throws {
        let plist = "Applications/WegaMacUpdater.app/Contents/Library/LaunchDaemons/\(WegaHelper.plistName)"
        let pkg = try buildPackage { payload in try FileManager.default.removeItem(at: payload.appendingPathComponent(plist)) }

        let result = try verify(pkg)

        XCTAssertEqual(result.status, 1, result.output)
    }

    /// Installer may put a relocatable bundle wherever a copy with its identifier already is,
    /// for example a dragged copy in Downloads, where the gate refuses it.
    func testARelocatableBundleFails() throws {
        let pkg = try buildPackage(relocatable: true)

        let result = try verify(pkg)

        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("relocat"), result.output)
    }

    /// The script checks exactly the entries the gate checks.
    func testTheScriptChecksEveryEntryOfTheGate() throws {
        let script = try String(contentsOf: packageRoot().appendingPathComponent("scripts/verify-pkg-payload.sh"), encoding: .utf8)
        for entry in HelperBundleEntry.allCases {
            let line = "    \"\(entry.relativePath.isEmpty ? "" : "/" + entry.relativePath)\""
            XCTAssertTrue(script.contains(line), "missing \(line)")
        }
        XCTAssertEqual(script.components(separatedBy: "\n").filter { $0.hasPrefix("    \"") && $0.hasSuffix("\"") }.count,
                       HelperBundleEntry.allCases.count)
    }

    /// `build-pkg.sh` fixes the builder's umask before it creates anything, and checks the package
    /// it built, signed or not.
    func testBuildPkgSetsTheUmaskAndChecksThePackage() throws {
        let build = try String(contentsOf: packageRoot().appendingPathComponent("scripts/build-pkg.sh"), encoding: .utf8)
        let umask = try XCTUnwrap(build.range(of: "\numask 022\n"))
        let firstFolder = try XCTUnwrap(build.range(of: "mkdir -p"))
        XCTAssertLessThan(umask.lowerBound, firstFolder.lowerBound)
        let check = try XCTUnwrap(build.range(of: "\n./scripts/verify-pkg-payload.sh \"$OUTPUT_PKG\"\n"))
        let lastPackage = try XCTUnwrap(build.range(of: "pkgbuild \\", options: .backwards))
        XCTAssertLessThan(lastPackage.lowerBound, check.lowerBound)
    }

    // MARK: - Fixtures

    /// A pkgbuild package of a minimal Wega bundle, folders 0755 and files 0644 (the helper 0755).
    private func buildPackage(relocatable: Bool = false, change: (URL) throws -> Void = { _ in }) throws -> URL {
        let payload = root.appendingPathComponent("payload")
        let bundle = payload.appendingPathComponent("Applications/WegaMacUpdater.app")
        for entry in HelperBundleEntry.allCases {
            let url = entry.relativePath.isEmpty ? bundle : bundle.appendingPathComponent(entry.relativePath)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: url)
            }
            try chmod(url, entry == .helperExecutable || entry.isDirectory ? 0o755 : 0o644)
        }
        for folder in [payload, payload.appendingPathComponent("Applications")] { try chmod(folder, 0o755) }
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.wega.tests.payload", "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "WegaPrivilegedHelper", "CFBundleShortVersionString": "1.0",
        ], format: .xml, options: 0).write(to: info)
        try chmod(info, 0o644)
        try change(payload)

        var arguments = ["--root", payload.path, "--install-location", "/", "--ownership", "recommended",
                         "--identifier", "com.wega.tests.payload", "--version", "1"]
        if relocatable {
            let components = root.appendingPathComponent("components.plist")
            XCTAssertEqual(try run("/usr/bin/pkgbuild", ["--analyze", "--root", payload.path, components.path]).status, 0)
            XCTAssertEqual(try run("/usr/bin/plutil", ["-replace", "0.BundleIsRelocatable", "-bool", "YES", components.path]).status, 0)
            arguments += ["--component-plist", components.path]
        }
        let pkg = root.appendingPathComponent("Wega.pkg")
        let built = try run("/usr/bin/pkgbuild", arguments + [pkg.path])
        XCTAssertEqual(built.status, 0, built.output)
        return pkg
    }

    private func verify(_ pkg: URL) throws -> (status: Int32, output: String) {
        try run(packageRoot().appendingPathComponent("scripts/verify-pkg-payload.sh").path, [pkg.path])
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
