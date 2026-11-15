import XCTest
@testable import MacUpdaterCore

final class ProcessOutputPolicyTests: XCTestCase {
    func testNullDeviceStdinGivesTheChildAnEmptyInput() async throws {
        var request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cat; printf done"],
            timeout: 5,
            idleTimeout: 5
        )
        request.standardInput = .nullDevice
        let result = try await ProcessRunner().run(request)
        XCTAssertEqual(result.stdout, "done")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testNullDeviceStdinIsWiredToTheNullDevice() {
        let process = Process()
        ProcessRunner.applyStandardInput(.nullDevice, to: process)
        XCTAssertEqual((process.standardInput as? FileHandle)?.fileDescriptor,
                       FileHandle.nullDevice.fileDescriptor)
    }

    func testInheritStdinLeavesTheProcessInputUnset() {
        let process = Process()
        let untouched = process.standardInput as? FileHandle
        ProcessRunner.applyStandardInput(.inherit, to: process)
        XCTAssertTrue((process.standardInput as? FileHandle) === untouched)
        XCTAssertNotEqual((process.standardInput as? FileHandle)?.fileDescriptor,
                          FileHandle.nullDevice.fileDescriptor)
    }

    func testSuppressedLoggingKeepsStderrOutOfTheExitDetail() {
        let detail = ProcessRunner.exitLogDetail(
            command: "zsh", exitCode: 1, stderr: "TOKEN=abc", logging: .suppressed)
        XCTAssertNil(detail.output)
        XCTAssertEqual(detail.fields.first { $0.key == "exit" }?.value, "1")
    }

    func testFullLoggingKeepsStderrInTheExitDetail() {
        let detail = ProcessRunner.exitLogDetail(
            command: "brew", exitCode: 1, stderr: "Error: x", logging: .full)
        XCTAssertEqual(detail.output, "Error: x")
    }

    func testDefaultsPreserveTodaysBehaviour() {
        let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/bin/true"))
        XCTAssertEqual(request.standardInput, .inherit)
        XCTAssertEqual(request.outputLogging, .full)
    }
}
