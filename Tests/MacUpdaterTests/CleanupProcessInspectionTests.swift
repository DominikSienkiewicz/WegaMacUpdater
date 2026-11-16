import Foundation
import XCTest
@testable import MacUpdaterCore

final class CleanupProcessInspectionTests: XCTestCase {
    /// A `KERN_PROCARGS2` buffer as the kernel lays it out: the executable path and its NUL are
    /// padded with NULs to a multiple of 8 bytes, counted from the path's first byte (offset 4).
    private func buffer(argc: Int32, executable: String, strings: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        let path = Array(executable.utf8) + [0]
        bytes += path + [UInt8](repeating: 0, count: (8 - path.count % 8) % 8)
        for string in strings {
            bytes += Array(string.utf8) + [0]
        }
        return bytes
    }

    private func process(_ path: String, arguments: [String] = []) -> CleanupProcess {
        CleanupProcess(pid: 7, name: "p", executablePath: path, arguments: arguments)
    }

    private func url(_ path: String, directory: Bool) -> URL {
        URL(filePath: path, directoryHint: directory ? .isDirectory : .notDirectory)
    }

    func testParserReturnsArgumentsAndNeverTheEnvironment() {
        let bytes = buffer(
            argc: 2, executable: "/x/claude",
            strings: ["/x/claude", "--chrome-native-host", "GITHUB_TOKEN=secret"]
        )
        let result = ProcArgs2Parser.arguments(from: bytes)
        XCTAssertEqual(result, ["/x/claude", "--chrome-native-host"])
        XCTAssertFalse((result ?? []).joined().contains("secret"))
    }

    /// An empty argv[0] is a lone NUL right after the padding; skipping every NUL there would
    /// take argv[1] for argv[0] and hand out the first environment variable as the last argument.
    func testEmptyFirstArgumentNeverReturnsTheEnvironment() {
        let bytes = buffer(argc: 2, executable: "/bin/sleep", strings: ["", "30", "WEGA_PROBE=envleak"])

        let result = ProcArgs2Parser.arguments(from: bytes)

        XCTAssertEqual(result, ["", "30"])
        XCTAssertFalse((result ?? []).contains { $0.contains("envleak") }, "an environment variable was returned")
    }

    func testPathThatFillsItsAlignmentHasNoPadding() {
        let bytes = buffer(argc: 2, executable: "/x/abcd", strings: ["", "-v", "TOKEN=1"])

        XCTAssertEqual(bytes.count, 4 + 8 + 1 + 3 + 8, "precondition: no padding after a path of 7 bytes")
        XCTAssertEqual(ProcArgs2Parser.arguments(from: bytes), ["", "-v"])
    }

    func testParserRejectsTruncatedBuffer() {
        XCTAssertNil(ProcArgs2Parser.arguments(from: [1, 0, 0]))
    }

    func testParserRejectsBufferThatEndsInsideThePathPadding() {
        let header = withUnsafeBytes(of: Int32(0)) { Array($0) }

        XCTAssertNil(ProcArgs2Parser.arguments(from: header + Array("/x/a".utf8) + [0]))
        XCTAssertNil(ProcArgs2Parser.arguments(from: header + Array("/x/a".utf8)), "a path without its NUL")
    }

    func testParserRejectsBufferThatEndsBeforeAllArguments() {
        let bytes = buffer(argc: 3, executable: "/x/a", strings: ["/x/a", "-v"])
        XCTAssertNil(ProcArgs2Parser.arguments(from: bytes))
    }

    func testParserRejectsNegativeArgc() {
        XCTAssertNil(ProcArgs2Parser.arguments(from: buffer(argc: -1, executable: "/x/a", strings: ["/x/a"])))
    }

    func testParserReturnsNoArgumentsForZeroArgc() {
        XCTAssertEqual(ProcArgs2Parser.arguments(from: buffer(argc: 0, executable: "/x/a", strings: ["A=1"])), [])
    }

    func testProcessWithoutPathIsSkipped() {
        XCTAssertNil(LiveProcessInspector.process(pid: 42, path: nil, procArgs: nil))
    }

    func testProcessKeepsNameAndArgumentsFromTheKernelBuffer() {
        let bytes = buffer(argc: 1, executable: "/x/claude", strings: ["/x/claude", "TOKEN=1"])
        XCTAssertEqual(
            LiveProcessInspector.process(pid: 42, path: "/x/claude", procArgs: bytes),
            CleanupProcess(pid: 42, name: "claude", executablePath: "/x/claude", arguments: ["/x/claude"])
        )
    }

    func testProcessWithDeniedArgumentsIsStillReturned() {
        XCTAssertEqual(
            LiveProcessInspector.process(pid: 5, path: "/x/y/tool", procArgs: nil),
            CleanupProcess(pid: 5, name: "tool", executablePath: "/x/y/tool", arguments: [])
        )
    }

    func testMatcherFindsTheProcessExecutingAnOldVersion() {
        let old = "/h/.local/share/claude/versions/2.1.318"
        let running = process(old)
        let other = process("/h/.local/share/claude/versions/2.1.400")
        let matches = CleanupInUseMatcher.processes(
            using: url(old, directory: false), isDirectory: false, among: [running, other]
        )
        XCTAssertEqual(matches, [running])
    }

    func testMatcherUsesComponentBoundaries() {
        let matches = CleanupInUseMatcher.processes(
            using: url("/h/versions/2.1.3", directory: true), isDirectory: true,
            among: [process("/h/versions/2.1.318")]
        )
        XCTAssertEqual(matches, [])
    }

    func testMatcherFindsExecutableUnderADirectory() {
        let running = process("/h/versions/2.1.3/bin/tool")
        XCTAssertEqual(
            CleanupInUseMatcher.processes(
                using: url("/h/versions/2.1.3", directory: true), isDirectory: true, among: [running]
            ),
            [running]
        )
    }

    func testMatcherFindsAnArgumentUnderADirectory() {
        let running = process("/usr/bin/node", arguments: ["node", "/h/versions/2.1.3/lib/cli.js"])
        XCTAssertEqual(
            CleanupInUseMatcher.processes(
                using: url("/h/versions/2.1.3", directory: true), isDirectory: true, among: [running]
            ),
            [running]
        )
    }

    func testMatcherIgnoresRelativeAndSiblingArguments() {
        let running = process("/usr/bin/node", arguments: ["h/versions/2.1.3/x", "/h/versions/2.1.30/x", "/h/versions"])
        XCTAssertEqual(
            CleanupInUseMatcher.processes(
                using: url("/h/versions/2.1.3", directory: true), isDirectory: true, among: [running]
            ),
            []
        )
    }

    func testMatcherFindsAnArgumentEqualToTheTargetFile() {
        let running = process("/usr/bin/node", arguments: ["node", "/h/app/cli.js"])
        XCTAssertEqual(
            CleanupInUseMatcher.processes(
                using: url("/h/app/cli.js", directory: false), isDirectory: false, among: [running]
            ),
            [running]
        )
    }

    func testMatcherComparesScalarsNotCharacters() {
        let running = process("/h/versions/2.1.3\u{0301}/tool")
        XCTAssertEqual(
            CleanupInUseMatcher.processes(
                using: url("/h/versions/2.1.3", directory: true), isDirectory: true, among: [running]
            ),
            []
        )
    }
}
