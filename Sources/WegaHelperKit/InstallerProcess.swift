import Foundation

/// The installer is monitored to completion, never killed merely because its XPC client left.
/// Run on a worker queue: status queries must remain available while it is running.
public enum InstallerProcess {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let standardError: String
    }

    public static func run(executable: URL, arguments: [String], outputLimit: Int = 64 * 1024) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()

        let output = InstallerOutputTail(limit: max(0, outputLimit))
        let drained = DispatchGroup()
        for (handle, retain) in [(stdout.fileHandleForReading, false), (stderr.fileHandleForReading, true)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { handle.closeFile(); drained.leave() }
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    if retain { output.append(data) }
                }
            }
        }
        process.waitUntilExit()
        drained.wait()
        return Result(exitCode: process.terminationStatus, standardError: output.string)
    }
}

private final class InstallerOutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    init(limit: Int) { self.limit = limit }

    func append(_ bytes: Data) {
        lock.withLock {
            data.append(bytes)
            if data.count > limit { data.removeFirst(data.count - limit) }
        }
    }

    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
