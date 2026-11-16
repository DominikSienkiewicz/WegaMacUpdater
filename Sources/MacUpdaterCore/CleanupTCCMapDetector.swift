import Foundation

/// D10: the user's "Files and Folders" entries, one finding per client. A path entry is tied to the
/// copy of a tool D1 or D3 found, so the duplicates section can say which entry belongs to which
/// copy; an entry for an app bundle gets a per-service `tccutil reset` command. Nothing here
/// changes the database, and every path entry is looked at through the guarded file system.
public struct CleanupTCCMapDetector: Sendable {
    private enum ClientType {
        static let bundle = 0
        static let path = 1
    }

    private struct Client {
        let name: String
        let type: Int
        var grants: [CleanupTCCService: Bool]

        var orderedGrants: [CleanupTCCGrant] {
            CleanupTCCService.allCases.compactMap { service in
                grants[service].map { CleanupTCCGrant(service: service, allowed: $0) }
            }
        }
    }

    private static let allowedAuthValues: Set<Int> = [2, 3]
    private static let bundleIDLeadingScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let bundleIDScalars = bundleIDLeadingScalars.union(CharacterSet(charactersIn: ".-"))

    private let database: CleanupTCCDatabaseReading
    private let fileSystem: CleanupFileSystem

    public init(database: CleanupTCCDatabaseReading, fileSystem: CleanupFileSystem) {
        self.database = database
        self.fileSystem = fileSystem
    }

    /// `linkingTo`: D1 findings and D3 findings (app-managed copies are D3 findings with status `.appManaged`).
    /// Database errors become notes, except a switch turned off during the scan, which yields
    /// nothing at all; any other error is rethrown (the scanner records `.failed`).
    public func scan(linkingTo findings: [CleanupFinding]) throws -> (findings: [CleanupFinding], notes: [CleanupDetectorNote]) {
        let rows: [CleanupTCCRow]
        do {
            rows = try database.rows(for: CleanupTCCService.allCases)
        } catch CleanupTCCDatabaseError.unreadable {
            return ([], [Self.note(.tccUnreadable)])
        } catch CleanupTCCDatabaseError.unsupportedSchema {
            return ([], [Self.note(.tccUnsupportedSchema)])
        } catch CleanupTCCDatabaseError.switchedOff {
            return ([], [])
        }
        // Two spellings of one path (`/x` and `/x/`) share an id; only the first finding is kept.
        var seen: Set<String> = []
        let map = Self.clients(in: rows)
            .compactMap { finding(for: $0, linkingTo: findings) }
            .filter { seen.insert($0.id).inserted }
        return (map, map.isEmpty ? [Self.note(.tccMapEmpty)] : [])
    }

    /// Clients in first-occurrence order; a row for a service outside `CleanupTCCService` is ignored.
    private static func clients(in rows: [CleanupTCCRow]) -> [Client] {
        var clients: [Client] = []
        for row in rows {
            guard let service = CleanupTCCService(rawValue: row.service) else { continue }
            let allowed = allowedAuthValues.contains(row.authValue)
            if let index = clients.firstIndex(where: { $0.name == row.client && $0.type == row.clientType }) {
                if clients[index].grants[service] == nil { clients[index].grants[service] = allowed }
            } else {
                clients.append(Client(name: row.client, type: row.clientType, grants: [service: allowed]))
            }
        }
        return clients
    }

    private func finding(for client: Client, linkingTo findings: [CleanupFinding]) -> CleanupFinding? {
        switch client.type {
        case ClientType.path: pathFinding(client, linkingTo: findings)
        case ClientType.bundle: bundleFinding(client)
        default: nil
        }
    }

    private func pathFinding(_ client: Client, linkingTo findings: [CleanupFinding]) -> CleanupFinding? {
        guard CleanupPathText.isAbsolute(client.name), !CleanupPathText.containsNUL(client.name) else { return nil }
        let url = URL(filePath: client.name, directoryHint: .notDirectory)
        let tool = CleanupPathText.components(of: client.name).last ?? client.name
        let grants = client.orderedGrants
        func makeFinding(
            _ status: CleanupStatus, _ reason: CleanupReason, _ action: CleanupAction,
            realpath: URL? = nil, identity: CleanupFileIdentity? = nil
        ) -> CleanupFinding {
            CleanupFinding(
                detector: .tccMap, tool: tool, path: url, realpath: realpath, source: nil, version: nil, size: nil,
                status: status, reason: reason, action: action, risk: .low, bucket: .excluded, identity: identity
            )
        }
        let entry: CleanupEntry?
        do {
            entry = try fileSystem.entry(at: url)
        } catch CleanupFileSystemError.protectedLocation {
            return makeFinding(.skippedProtected, .protectedLocation, .none)
        } catch {
            return makeFinding(.info, .tccEntry(grants: grants, link: nil), .none)
        }
        guard let entry else {
            return makeFinding(.deadEntry, .tccEntryFileGone(grants: grants), .instruction(.switchOffInFilesAndFolders))
        }
        let realpath = try? fileSystem.realpath(url)
        let link = Self.link(for: url, realpath: realpath, in: findings)
        let action: CleanupAction = link?.kind == .copyToRemove ? .instruction(.switchOffInFilesAndFolders) : .none
        return makeFinding(.info, .tccEntry(grants: grants, link: link), action, realpath: realpath, identity: entry.identity)
    }

    /// The first D1 finding whose `path` or `realpath` is the client or the client's realpath, else the
    /// first D3 finding whose `path` is or contains one of them. Compared by scalar path components.
    private static func link(for client: URL, realpath: URL?, in findings: [CleanupFinding]) -> CleanupTCCLink? {
        let places = [client, realpath].compactMap { $0.map { CleanupPathText.components(of: $0.path) } }
        func isPlace(_ url: URL?) -> Bool {
            url.map { places.contains(CleanupPathText.components(of: $0.path)) } ?? false
        }
        let copy = findings.first { finding in
            finding.detector == .pathDuplicates && (isPlace(finding.path) || isPlace(finding.realpath))
        } ?? findings.first { finding in
            let directory = CleanupPathText.components(of: finding.path.path)
            return finding.detector == .versionDirectories && places.contains { $0.starts(with: directory) }
        }
        return copy.map { CleanupTCCLink(findingID: $0.id, kind: linkKind(of: $0)) }
    }

    private static func linkKind(of finding: CleanupFinding) -> CleanupTCCLinkKind {
        switch finding.status {
        case .active:
            return .activeCopy
        case .shadowed, .unused, .inUse, .stale:
            return .copyToRemove
        case .appManaged:
            if case .appManaged(let owner) = finding.source { return .appManaged(owner: owner) }
            return .keptCopy
        case .expected, .dependency, .brokenLink, .skippedProtected, .info, .pinned, .recentUpgrade, .deadEntry:
            return .keptCopy
        }
    }

    private func bundleFinding(_ client: Client) -> CleanupFinding {
        let grants = client.orderedGrants
        let action: CleanupAction
        if Self.isSafeBundleID(client.name) {
            action = .command(grants.map { "tccutil reset \($0.service.tccutilName) \(client.name)" }.joined(separator: "; "))
        } else {
            action = .none
        }
        return CleanupFinding(
            detector: .tccMap, tool: client.name, path: database.fileURL, realpath: nil,
            source: .appBundle(name: client.name), version: nil, size: nil, status: .info,
            reason: .tccEntry(grants: grants, link: nil), action: action, risk: .low, bucket: .excluded, identity: nil
        )
    }

    /// An ASCII letter or digit first, then only `[A-Za-z0-9.-]`, so the id can be pasted into a shell
    /// command as it is and never reads as a `tccutil` option.
    private static func isSafeBundleID(_ bundleID: String) -> Bool {
        guard let first = bundleID.unicodeScalars.first, bundleIDLeadingScalars.contains(first) else { return false }
        return bundleID.unicodeScalars.allSatisfy { bundleIDScalars.contains($0) }
    }

    private static func note(_ kind: CleanupDetectorNote.Kind) -> CleanupDetectorNote {
        CleanupDetectorNote(detector: .tccMap, kind: kind)
    }
}
