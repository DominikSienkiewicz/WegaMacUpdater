import Darwin
import Foundation

/// Lists the current user's processes and the last boot, without reading any environment.
public protocol ProcessInspecting: Sendable {
    func userProcesses() -> [CleanupProcess]
    func bootTime() -> Date
}

/// Reads the arguments out of a `KERN_PROCARGS2` buffer: `Int32 argc`, the executable path,
/// then `argc` NUL-terminated strings. Everything after the `argc`-th string is the environment,
/// which can carry tokens, and is never looked at.
///
/// The kernel pads the path and its NUL to a multiple of 8 bytes counted from the path's first
/// byte. Exactly that padding is skipped: an empty argument is a lone NUL, so skipping every NUL
/// after the path would shift the arguments by one and return the first environment variable.
public enum ProcArgs2Parser {
    private static let pathAlignment = 8

    public static func arguments(from buffer: [UInt8]) -> [String]? {
        let headerSize = MemoryLayout<Int32>.size
        guard buffer.count >= headerSize else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }

        var index = headerSize
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        let pathLength = index - headerSize + 1
        index = headerSize + (pathLength + pathAlignment - 1) / pathAlignment * pathAlignment
        guard index <= buffer.count else { return nil }

        var arguments: [String] = []
        while arguments.count < Int(argc) {
            guard let end = buffer[index...].firstIndex(of: 0) else { return nil }
            arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }
}

/// Uses libproc and sysctl only: no `ps`, no `lsof`, and never the environment half of
/// `KERN_PROCARGS2`.
public struct LiveProcessInspector: ProcessInspecting {
    public init() {}

    public func userProcesses() -> [CleanupProcess] {
        let uid = getuid()
        let byteCount = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard byteCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 16)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size)
            .filter { $0 > 0 }
            .compactMap { Self.process(pid: $0, path: Self.path(of: $0), procArgs: Self.procArgs(of: $0)) }
    }

    public func bootTime() -> Date {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, UInt32(mib.count), &boot, &size, nil, 0) == 0 else {
            return Date(timeIntervalSince1970: 0)
        }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }

    static func process(pid: Int32, path: String?, procArgs: [UInt8]?) -> CleanupProcess? {
        guard let path else { return nil }
        let name = CleanupPathText.components(of: path).last ?? path
        let arguments = procArgs.flatMap(ProcArgs2Parser.arguments(from:)) ?? []
        return CleanupProcess(pid: pid, name: name, executablePath: path, arguments: arguments)
    }

    private static func path(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a macro Swift does not import; it is 4 * MAXPATHLEN.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func procArgs(of pid: pid_t) -> [UInt8]? {
        var maxMib = [CTL_KERN, KERN_ARGMAX]
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        guard sysctl(&maxMib, UInt32(maxMib.count), &argMax, &argMaxSize, nil, 0) == 0, argMax > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var size = buffer.count
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }
}

/// Decides which running processes still use a path that is about to be removed.
///
/// Paths are compared as arrays of components split on Unicode scalars, so `2.1.3` never matches
/// `2.1.318` and a combining mark after a slash cannot hide a boundary.
public enum CleanupInUseMatcher {
    public static func processes(using target: URL, isDirectory: Bool, among: [CleanupProcess]) -> [CleanupProcess] {
        let targetComponents = CleanupPathText.components(of: target.path)
        return among.filter { process in
            if isUnder(CleanupPathText.components(of: process.executablePath), targetComponents, orEqual: true) {
                return true
            }
            return process.arguments.contains { argument in
                guard CleanupPathText.isAbsolute(argument) else { return false }
                return isUnder(CleanupPathText.components(of: argument), targetComponents, orEqual: !isDirectory)
            }
        }
    }

    private static func isUnder(_ candidate: [String], _ root: [String], orEqual: Bool) -> Bool {
        guard !root.isEmpty, candidate.starts(with: root) else { return false }
        return orEqual || candidate.count > root.count
    }
}
