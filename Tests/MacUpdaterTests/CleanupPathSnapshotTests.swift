import XCTest
@testable import MacUpdaterCore

final class CleanupPathSnapshotTests: XCTestCase {
    private let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)

    func testZshRequestIsInteractiveLoginWithMinimalEnvironment() throws {
        let request = try XCTUnwrap(CleanupPathReader.request(shellPath: "/bin/zsh", home: home, user: "tester"))

        XCTAssertEqual(request.executableURL.path, "/bin/zsh")
        XCTAssertEqual(request.arguments, ["-ilc", "print -rn -- \"__WEGA_PATH_BEGIN__${PATH}__WEGA_PATH_END__\""])
        XCTAssertEqual(request.environment, [
            "HOME": "/Users/tester", "USER": "tester", "LOGNAME": "tester", "SHELL": "/bin/zsh",
            "LANG": "en_US.UTF-8", "TERM": "dumb", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ])
        XCTAssertFalse(request.inheritParentEnvironment)
        XCTAssertEqual(request.standardInput, .nullDevice)
        XCTAssertEqual(request.outputLogging, .suppressed)
        XCTAssertEqual(request.timeout, 10)
        XCTAssertEqual(request.idleTimeout, 10)
    }

    /// M5: a job started from `.zshrc` can hold the shell's output open long after the shell
    /// exits; the read stops waiting for it after two seconds instead of hanging the screen.
    func testRequestBoundsTheOutputDrain() throws {
        let request = try XCTUnwrap(CleanupPathReader.request(shellPath: "/bin/zsh", home: home, user: "tester"))

        XCTAssertEqual(request.outputDrainLimit, 2)
    }

    func testCancelledRunReadsAsCancelled() async {
        let cancelled = [
            ScriptedPathRunner(.failure(ProcessRunnerError.cancelled)),
            ScriptedPathRunner(.failure(CancellationError())),
        ]
        let failing = [
            ScriptedPathRunner(.failure(ProcessRunnerError.timedOut(seconds: 10))),
            ScriptedPathRunner(.failure(ScriptedPathRunner.Boom())),
        ]

        for (runners, expected) in [(cancelled, CleanupPathReadResult.cancelled), (failing, .failed)] {
            for runner in runners {
                let reader = CleanupPathReader(
                    runner: runner, shellPath: "/bin/zsh", home: home, user: "tester", now: { Date() }
                )
                let result = await reader.read()
                XCTAssertEqual(result, expected)
            }
        }
    }

    func testBashRequestUsesPrintf() throws {
        let request = try XCTUnwrap(CleanupPathReader.request(shellPath: "/bin/bash", home: home, user: "tester"))

        XCTAssertEqual(request.arguments, ["-ilc", "printf '%s' \"__WEGA_PATH_BEGIN__${PATH}__WEGA_PATH_END__\""])
    }

    func testFishIsUnsupported() async {
        XCTAssertNil(CleanupPathReader.request(shellPath: "/opt/homebrew/bin/fish", home: home, user: "tester"))

        let runner = ScriptedPathRunner(.success(ProcessResult(exitCode: 0, stdout: "", stderr: "")))
        let reader = CleanupPathReader(
            runner: runner, shellPath: "/opt/homebrew/bin/fish", home: home, user: "tester", now: { Date() }
        )
        let result = await reader.read()

        XCTAssertEqual(result, .unsupportedShell("fish"))
        XCTAssertEqual(runner.runCount, 0)
    }

    func testParseIgnoresBannerNoiseAroundTheMarkers() throws {
        let parsed = try XCTUnwrap(
            CleanupPathReader.parse(stdout: "Welcome!\n__WEGA_PATH_BEGIN__/a:/b__WEGA_PATH_END__\nbye")
        )

        XCTAssertEqual(parsed.entries, ["/a", "/b"])
        XCTAssertEqual(parsed.ignored, [])
    }

    func testParseKeepsDuplicatesAndSetsAsideRelativeAndEmptyEntries() throws {
        let parsed = try XCTUnwrap(
            CleanupPathReader.parse(stdout: "__WEGA_PATH_BEGIN__/a::bin:.:/a__WEGA_PATH_END__")
        )

        XCTAssertEqual(parsed.entries, ["/a", "/a"])
        XCTAssertEqual(parsed.ignored, ["", "bin", "."])
    }

    func testFailedOrMarkerlessReadYieldsFailed() async {
        let failing = ScriptedPathRunner(.success(ProcessResult(exitCode: 1, stdout: "__WEGA_PATH_BEGIN__/a__WEGA_PATH_END__", stderr: "")))
        let markerless = ScriptedPathRunner(.success(ProcessResult(exitCode: 0, stdout: "no markers", stderr: "")))
        let throwing = ScriptedPathRunner(.failure(ScriptedPathRunner.Boom()))

        for runner in [failing, markerless, throwing] {
            let reader = CleanupPathReader(
                runner: runner, shellPath: "/bin/zsh", home: home, user: "tester", now: { Date() }
            )
            let result = await reader.read()
            XCTAssertEqual(result, .failed)
        }
    }

    func testSuccessfulReadIsCapturedWithShellAndTimestamp() async {
        let stamp = Date(timeIntervalSince1970: 1_000)
        let runner = ScriptedPathRunner(.success(ProcessResult(
            exitCode: 0, stdout: "x__WEGA_PATH_BEGIN__/a:rel__WEGA_PATH_END__", stderr: ""
        )))
        let reader = CleanupPathReader(
            runner: runner, shellPath: "/bin/zsh", home: home, user: "tester", now: { stamp }
        )

        let result = await reader.read()

        XCTAssertEqual(result, .captured(CleanupPathSnapshot(
            entries: ["/a"], ignoredEntries: ["rel"], shell: "zsh", capturedAt: stamp, isApproximate: false
        )))
    }

    func testApproximatePathFollowsEtcPathsThenPathsDThenKnownDirs() {
        let fileSystem = FixedTextCleanupFileSystem(
            texts: [
                "/etc/paths": "/usr/local/bin\n /usr/bin \n\nrelative\n",
                "/etc/paths.d/20-b": "/b",
                "/etc/paths.d/10-a": "/a\n",
            ],
            children: ["/etc/paths.d": ["20-b", "10-a"]],
            existing: ["/Users/tester/.local/bin", "/usr/local/bin"]
        )

        let snapshot = CleanupApproximatePath.build(fileSystem: fileSystem, home: home)

        XCTAssertEqual(snapshot.entries, ["/usr/local/bin", "/usr/bin", "/a", "/b", "/Users/tester/.local/bin"])
        XCTAssertTrue(snapshot.isApproximate)
        XCTAssertNil(snapshot.shell)
        XCTAssertNil(snapshot.capturedAt)
    }

    func testApproximatePathSurvivesMissingEtcFiles() {
        let snapshot = CleanupApproximatePath.build(fileSystem: FixedTextCleanupFileSystem(), home: home)

        XCTAssertEqual(snapshot.entries, [])
        XCTAssertTrue(snapshot.isApproximate)
    }

    func testSnapshotRoundTripsThroughTheFile() throws {
        let io = InMemoryPathSnapshotIO()
        let file = CleanupPathSnapshotFile(io: io)
        let snapshot = CleanupPathSnapshot(
            entries: ["/a", "/b"], ignoredEntries: [""], shell: "zsh",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000), isApproximate: false
        )

        XCTAssertNil(file.load())
        try file.save(snapshot)

        XCTAssertEqual(file.load(), snapshot)
    }

    func testCorruptFileLoadsAsNil() throws {
        let io = InMemoryPathSnapshotIO()
        try io.write(Data("not json".utf8))

        XCTAssertNil(CleanupPathSnapshotFile(io: io).load())
    }

    func testDefaultFileLivesInApplicationSupport() {
        XCTAssertTrue(CleanupPathSnapshotFile.defaultFileURL.path.hasSuffix("/WegaMacUpdater/cleanup-path.json"))
    }
}

private final class ScriptedPathRunner: ProcessRunning, @unchecked Sendable {
    struct Boom: Error {}

    private let outcome: Result<ProcessResult, Error>
    private let lock = NSLock()
    private var count = 0

    init(_ outcome: Result<ProcessResult, Error>) {
        self.outcome = outcome
    }

    var runCount: Int { lock.withLock { count } }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.withLock { count += 1 }
        return try outcome.get()
    }

    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: Boom()) }
    }
}

private final class InMemoryPathSnapshotIO: ScanSnapshotIO {
    private var data: Data?

    func read() throws -> Data? { data }

    func write(_ data: Data) throws { self.data = data }
}
