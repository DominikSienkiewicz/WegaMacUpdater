import Foundation
import Testing
@testable import WegaHelperKit

/// A temporary directory that stands in for `/` when the Touch ID card's Terminal commands run in a
/// test: every path the commands name is moved under it, so they run on the real `/bin/sh` and
/// `/usr/bin` tools, without `sudo`, and touch nothing outside it.
struct PolicyShellSandbox {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-policy-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("etc/pam.d", isDirectory: true), withIntermediateDirectories: true)
        root = base.path
    }

    var policyDirectory: String { moved(SystemPaths.pamPolicyDisplayDirectory) }
    var sudoLocal: String { moved(SystemPaths.sudoLocal) }
    var template: String { moved(SystemPaths.sudoLocalTemplate) }
    var fallbackPaths: [String] { TouchIDSudoDisabler.fallbackPolicyPaths.map(moved) }
    var localDirectories: [String] { ["/usr/local", "/usr/local/etc", "/usr/local/etc/pam.d"].map(moved) }

    func moved(_ path: String) -> String { root + path }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }

    func write(_ bytes: [UInt8], to path: String, permissions: Int = 0o644) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
    }

    func contents(of path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func permissions(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }

    /// The names a command created in the policy directory and left there.
    func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: policyDirectory)
            .filter { $0.hasPrefix(TouchIDSudoDisabler.swapNamePrefix) }
    }
}

/// The two locales a pasted command meets: Terminal's UTF-8 one, which `sudo` passes on, and C.
enum ShellLocale: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case polishUTF8
    case c

    var testDescription: String { rawValue }

    var environment: [String: String] {
        let path = "/usr/bin:/bin:/usr/sbin:/sbin"
        switch self {
        case .polishUTF8: return ["LANG": "pl_PL.UTF-8", "PATH": path]
        case .c: return ["LANG": "C", "LC_ALL": "C", "PATH": path]
        }
    }
}

struct ShellRun {
    let status: Int32
    let output: String
}

enum PolicyShell {
    /// Runs `script` with `/bin/sh -c`. The wait suspends on the termination handler instead of
    /// blocking a thread of the cooperative pool.
    static func run(_ script: String, in locale: ShellLocale, arguments: [String] = []) async throws -> ShellRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments + ["-c", script]
        process.environment = locale.environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return ShellRun(status: status, output: text)
    }
}
