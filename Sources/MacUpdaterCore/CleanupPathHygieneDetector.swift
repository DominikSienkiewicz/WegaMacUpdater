import Foundation

/// D9: the entries of the user's `PATH` that are dead, repeated, the same place as an earlier entry
/// or nested inside another one, and the tools whose active copy is older than a copy it shadows.
/// Every finding names the shell files and lines that mention the entry (`file:line`, never the
/// line's text). It works only on a `PATH` read from the shell; an approximated `PATH` reads nothing.
public struct CleanupPathHygieneDetector: Sendable {
    private enum Standing {
        case dead(CleanupEntry?)
        case alive(entry: CleanupEntry, realpath: URL)
        case undecided
    }

    private struct Candidate {
        let text: String
        let standing: Standing

        var physicalPath: URL? {
            if case .alive(_, let real) = standing { real } else { nil }
        }
    }

    private let fileSystem: CleanupFileSystem
    private let home: URL
    private let systemConfigurationDirectory: URL

    public init(fileSystem: CleanupFileSystem, home: URL, systemConfigurationDirectory: URL) {
        self.fileSystem = fileSystem
        self.home = home
        self.systemConfigurationDirectory = systemConfigurationDirectory
    }

    /// `duplicates` are the D1 findings. An approximated `PATH` yields nothing and touches nothing.
    public func scan(_ path: CleanupPathSnapshot, duplicates: [CleanupFinding]) -> (findings: [CleanupFinding], skippedProtected: [String]) {
        guard !path.isApproximate else { return ([], []) }
        let attribution = CleanupShellFileAttribution(
            shell: path.shell, home: home, systemConfigurationDirectory: systemConfigurationDirectory, fileSystem: fileSystem
        )
        var counts: [String: Int] = [:]
        var distinct: [String] = []
        for text in path.entries where CleanupPathText.isAbsolute(text) && !CleanupPathText.containsNUL(text) {
            counts[text, default: 0] += 1
            if counts[text] == 1 { distinct.append(text) }
        }
        let candidates = distinct.map { Candidate(text: $0, standing: standing(of: $0)) }
        var findings = candidates.enumerated().compactMap { index, candidate in
            entryFinding(candidate, earlier: candidates[..<index], all: candidates, count: counts[candidate.text] ?? 1, attribution: attribution)
        }
        findings += olderCopyFindings(duplicates, attribution: attribution)
        // Two spellings of one entry (`/x` and `/x/`) share an id; only the first finding is kept.
        var seen: Set<String> = []
        return (findings.filter { seen.insert($0.id).inserted }, attribution.skippedProtected)
    }

    private func standing(of text: String) -> Standing {
        let url = URL(filePath: text, directoryHint: .isDirectory)
        do {
            guard let entry = try fileSystem.entry(at: url) else { return .dead(nil) }
            switch entry.kind {
            case .file, .other:
                return .dead(entry)
            case .directory:
                return .alive(entry: entry, realpath: try fileSystem.realpath(url))
            case .symlink:
                let target: URL
                do { target = try fileSystem.realpath(url) } catch CleanupFileSystemError.notFound { return .dead(entry) }
                guard let resolved = try fileSystem.entry(at: target) else { return .dead(entry) }
                return resolved.kind == .directory ? .alive(entry: entry, realpath: target) : .dead(entry)
            }
        } catch CleanupFileSystemError.notFound {
            return .dead(nil)
        } catch {
            return .undecided
        }
    }

    private func entryFinding(
        _ candidate: Candidate, earlier: ArraySlice<Candidate>, all: [Candidate], count: Int,
        attribution: CleanupShellFileAttribution
    ) -> CleanupFinding? {
        let url = URL(filePath: candidate.text, directoryHint: .isDirectory)
        let locations = attribution.locations(of: candidate.text)
        func finding(_ status: CleanupStatus, _ reason: CleanupReason, realpath: URL?, identity: CleanupFileIdentity?) -> CleanupFinding {
            CleanupFinding(
                detector: .pathHygiene, tool: "PATH", path: url, realpath: realpath, source: nil, version: nil, size: nil,
                status: status, reason: reason,
                action: .instruction(.editShellFiles(entry: candidate.text, locations: locations)),
                risk: .low, bucket: .excluded, identity: identity
            )
        }
        switch candidate.standing {
        case .undecided:
            return nil
        case .dead(let entry):
            return finding(.deadEntry, .missingPathEntry, realpath: nil, identity: entry?.identity)
        case .alive(let entry, let real):
            let reason: CleanupReason
            if count >= 2 {
                reason = .repeatedPathEntry(count: count)
            } else if let same = earlier.first(where: { $0.physicalPath?.path == real.path }) {
                reason = .samePlaceAs(path: same.text)
            } else if let parent = all.first(where: { $0.text != candidate.text && Self.isStrictlyInside(real, parent: $0.physicalPath) }) {
                reason = .nestedIn(parent: parent.text)
            } else {
                return nil
            }
            return finding(.info, reason, realpath: real, identity: entry.identity)
        }
    }

    private static func isStrictlyInside(_ child: URL, parent: URL?) -> Bool {
        guard let parent else { return false }
        let childComponents = CleanupPathText.components(of: child.path)
        let parentComponents = CleanupPathText.components(of: parent.path)
        return childComponents.count > parentComponents.count && childComponents.starts(with: parentComponents)
    }

    private func olderCopyFindings(_ duplicates: [CleanupFinding], attribution: CleanupShellFileAttribution) -> [CleanupFinding] {
        var tools: [String] = []
        for finding in duplicates where finding.detector == .pathDuplicates && !tools.contains(finding.tool) {
            tools.append(finding.tool)
        }
        return tools.compactMap { tool in
            let group = duplicates.filter { $0.detector == .pathDuplicates && $0.tool == tool }
            guard let active = group.first(where: { $0.status == .active }), let version = active.version,
                  let newest = Self.newest(in: group), let newestVersion = newest.version,
                  compareVersions(version, newestVersion, scheme: .semver) == .orderedAscending else { return nil }
            let directory = active.path.deletingLastPathComponent().path
            return CleanupFinding(
                detector: .pathHygiene, tool: tool, path: active.path, realpath: active.realpath, source: nil,
                version: version, size: nil, status: .info,
                reason: .olderCopyWins(version: version, newer: newest.path.path, newerVersion: newestVersion),
                action: .instruction(.editShellFiles(entry: directory, locations: attribution.locations(of: directory))),
                risk: .low, bucket: .excluded, identity: active.identity
            )
        }
    }

    /// The copy with the highest known version among those that are not the active, a system or a broken copy.
    private static func newest(in group: [CleanupFinding]) -> CleanupFinding? {
        var best: CleanupFinding?
        for finding in group where counts(as: finding.status) {
            guard let version = finding.version else { continue }
            guard let current = best?.version else {
                best = finding
                continue
            }
            if compareVersions(version, current, scheme: .semver) == .orderedDescending { best = finding }
        }
        return best
    }

    private static func counts(as status: CleanupStatus) -> Bool {
        switch status {
        case .active, .expected, .brokenLink, .skippedProtected: false
        default: true
        }
    }
}
