import Foundation

struct CleanupShellStateLocation: Sendable {
    enum Base: Sendable {
        case home, tmp
    }

    let tool: String
    let base: Base
    let relativePath: String

    static let known = [
        CleanupShellStateLocation(tool: "fnm", base: .home, relativePath: ".local/state/fnm_multishells"),
        CleanupShellStateLocation(tool: "fnm", base: .tmp, relativePath: "fnm_multishells"),
    ]
}

/// `fnm env` leaves one symlink per invocation and never removes it. The PID in the name belongs
/// to that short-lived process, so a dead PID proves nothing; only a timestamp from before the
/// last boot proves that no shell using the entry can still be running.
struct CleanupShellStateDetector: Sendable {
    let fileSystem: CleanupFileSystem
    let home: URL
    let tmpDirectory: URL
    let inspector: ProcessInspecting

    func findings() throws -> [CleanupFinding] {
        let boot = inspector.bootTime()
        return try CleanupShellStateLocation.known.flatMap { location in
            try findings(in: location, bootTime: boot)
        }
    }

    /// The milliseconds since 1970 in a `<pid>_<ms>[_<suffix>]` name, or nil for any other name.
    static func timestamp(ofEntryNamed name: String) -> Date? {
        let scalars = Array(name.unicodeScalars)
        let pidEnd = scalars.prefix { isASCIIDigit($0) }.count
        guard pidEnd > 0, pidEnd < scalars.count, scalars[pidEnd] == "_" else { return nil }
        let rest = scalars[(pidEnd + 1)...]
        let digits = rest.prefix { isASCIIDigit($0) }
        guard digits.count >= minimumTimestampDigits else { return nil }
        let tail = rest.dropFirst(digits.count)
        if !tail.isEmpty {
            guard tail.first == "_", tail.count > 1 else { return nil }
        }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: digits)
        guard let milliseconds = Int64(String(text)) else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private static let minimumTimestampDigits = 10

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    private func findings(in location: CleanupShellStateLocation, bootTime: Date) throws -> [CleanupFinding] {
        let directory = url(of: location)
        guard let entry = try fileSystem.entry(at: directory) else { return [] }
        let scanned = ScannedDirectory(tool: location.tool, url: directory, identity: entry.identity)
        var stale: [CleanupEntry] = []
        var keptCount = 0
        for child in try fileSystem.contents(of: directory) where child.kind == .symlink {
            guard let created = Self.timestamp(ofEntryNamed: child.url.lastPathComponent) else { continue }
            if created < bootTime { stale.append(child) } else { keptCount += 1 }
        }
        var result: [CleanupFinding] = []
        if !stale.isEmpty {
            result.append(finding(
                in: scanned, status: .stale,
                reason: .staleSinceBoot(count: stale.count),
                action: .trashBatch(parent: directory, entries: stale.map(\.url).sorted { $0.lastPathComponent < $1.lastPathComponent }),
                size: stale.reduce(Int64(0)) { $0 + ((try? fileSystem.allocatedSize(of: $1.url)) ?? 0) }
            ))
        }
        if keptCount > 0 {
            result.append(finding(
                in: scanned, status: .info,
                reason: .keptSinceBoot(count: keptCount), action: .none, size: nil
            ))
        }
        return result
    }

    private func url(of location: CleanupShellStateLocation) -> URL {
        let base = location.base == .home ? home : tmpDirectory
        return base.appending(path: location.relativePath, directoryHint: .notDirectory)
    }

    private struct ScannedDirectory {
        let tool: String
        let url: URL
        let identity: CleanupFileIdentity
    }

    private func finding(
        in directory: ScannedDirectory, status: CleanupStatus, reason: CleanupReason,
        action: CleanupAction, size: Int64?
    ) -> CleanupFinding {
        CleanupFinding(
            detector: .shellState, tool: directory.tool, path: directory.url, realpath: nil, source: nil,
            version: nil, size: size, status: status, reason: reason, action: action, risk: .low,
            bucket: CleanupBucketPolicy.bucket(
                status: status, source: nil, relation: .notApplicable, recognisedLayout: true
            ),
            identity: directory.identity
        )
    }
}
