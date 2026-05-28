import XCTest
@testable import MacUpdaterCore

/// Why this shim exists: `mas upgrade` shells out to `sudo softwareupdate …`
/// for some MAS items (e.g. Safari extensions like "Proton Pass for Safari").
/// `sudo` only honours `SUDO_ASKPASS` when invoked with `-A`, and mas does not
/// pass `-A`. Without a controlling terminal this fails with
/// "sudo: a terminal is required to read the password".
///
/// The shim is a `sudo` wrapper placed earlier in `PATH` for child processes
/// of Wega; it transparently rewrites every `sudo …` call into `sudo -A …`,
/// which then uses the askpass helper we already install.
final class SudoShimTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wega-sudo-shim-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testInstallWritesExecutableSudoScript() throws {
        let dir = try SudoShim.install(in: tempDir)
        let script = dir.appendingPathComponent("sudo")

        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))
        let contents = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("#!"), "Missing shebang: \(contents.prefix(20))")
        XCTAssertTrue(contents.contains("/usr/bin/sudo"),
                      "Shim must delegate to real /usr/bin/sudo to avoid recursion")
        XCTAssertTrue(contents.contains("-A"),
                      "Shim must inject -A so sudo uses SUDO_ASKPASS")

        let attrs = try FileManager.default.attributesOfItem(atPath: script.path)
        let permissions = attrs[.posixPermissions] as? NSNumber
        XCTAssertNotNil(permissions)
        XCTAssertEqual((permissions!.intValue & 0o100), 0o100, "Script must be executable")
    }

    func testInstallIsIdempotent() throws {
        let first = try SudoShim.install(in: tempDir)
        let second = try SudoShim.install(in: tempDir)
        XCTAssertEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("sudo").path))
    }

    func testShimDirectoryIsPrependedToHomebrewPath() throws {
        let dir = try SudoShim.install(in: tempDir)
        HomebrewEnvironment.sudoShimDirectory = dir.path
        defer { HomebrewEnvironment.sudoShimDirectory = nil }

        let env = HomebrewEnvironment.environment
        let path = env["PATH"] ?? ""
        XCTAssertTrue(path.hasPrefix(dir.path + ":"),
                      "Shim directory must be the first entry in PATH so it shadows /usr/bin/sudo. Got: \(path)")
    }

    func testShimForwardsExitCodeAndArguments() throws {
        // End-to-end smoke: run the shim against a fake `sudo` that just echoes
        // its argv and exits 0 — proves the script invokes the resolved sudo
        // with `-A` prepended and forwards remaining args verbatim.
        let dir = try SudoShim.install(in: tempDir)
        let script = dir.appendingPathComponent("sudo")

        let fakeSudo = tempDir.appendingPathComponent("fake-sudo")
        try """
        #!/bin/bash
        printf '%s\\n' "$@"
        """.write(to: fakeSudo, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fakeSudo.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "softwareupdate", "-i", "-a"]
        process.environment = ["WEGA_SUDO_REAL": fakeSudo.path, "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let stdout = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(lines, ["-A", "softwareupdate", "-i", "-a"],
                       "Shim must prepend -A and forward the rest of argv unchanged")
    }
}
