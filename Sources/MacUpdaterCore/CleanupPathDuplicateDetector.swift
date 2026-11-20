import Foundation

public enum CleanupCopyRole: String, Codable, Equatable, Sendable {
    case active, shadowed, expected, brokenLink
}

public struct CleanupCopy: Equatable, Sendable {
    public let path: URL
    public let realpath: URL?
    public let pathIndex: Int
    public let source: CleanupSource
    public let version: String?
    public let identity: CleanupFileIdentity
    public let role: CleanupCopyRole

    public init(
        path: URL, realpath: URL?, pathIndex: Int, source: CleanupSource,
        version: String?, identity: CleanupFileIdentity, role: CleanupCopyRole
    ) {
        self.path = path
        self.realpath = realpath
        self.pathIndex = pathIndex
        self.source = source
        self.version = version
        self.identity = identity
        self.role = role
    }
}

public struct CleanupToolGroup: Equatable, Sendable {
    public let name: String
    public let copies: [CleanupCopy]

    public init(name: String, copies: [CleanupCopy]) {
        self.name = name
        self.copies = copies
    }
}

public struct CleanupPathScan: Equatable, Sendable {
    public let groups: [CleanupToolGroup]
    public let skippedProtected: [String]
    public let missingDirectories: [String]

    public init(groups: [CleanupToolGroup], skippedProtected: [String], missingDirectories: [String]) {
        self.groups = groups
        self.skippedProtected = skippedProtected
        self.missingDirectories = missingDirectories
    }
}

/// Finds the same tool name in several `PATH` directories. Every access goes through the injected
/// (guarded) file system; nothing is executed. Directories are listed once, and links are resolved
/// only for names that occur in at least two directories.
public struct CleanupPathDuplicateDetector: Sendable {
    private struct Candidate {
        let entry: CleanupEntry
        let pathIndex: Int
        let realpath: URL?
    }

    private struct Directory {
        let index: Int
        let children: [CleanupEntry]
    }

    private let fileSystem: CleanupFileSystem
    private let classifier: CleanupSourceClassifier

    public init(fileSystem: CleanupFileSystem, classifier: CleanupSourceClassifier) {
        self.fileSystem = fileSystem
        self.classifier = classifier
    }

    public func scan(_ path: CleanupPathSnapshot) -> CleanupPathScan {
        var skipped: [String] = []
        var missing: [String] = []
        var directories: [Directory] = []
        var seen: Set<String> = []
        for (index, text) in path.entries.enumerated()
        where CleanupPathText.isAbsolute(text) && !CleanupPathText.containsNUL(text) && seen.insert(text).inserted {
            let url = URL(filePath: text, directoryHint: .isDirectory)
            do {
                guard try fileSystem.entry(at: url) != nil else {
                    missing.append(text)
                    continue
                }
                directories.append(Directory(index: index, children: try fileSystem.contents(of: url)))
            } catch CleanupFileSystemError.protectedLocation {
                skipped.append(text)
            } catch {
                missing.append(text)
            }
        }

        var occurrences: [String: Int] = [:]
        for directory in directories {
            for name in Set(directory.children.map { $0.url.lastPathComponent }) {
                occurrences[name, default: 0] += 1
            }
        }
        var groups: [CleanupToolGroup] = []
        for name in occurrences.filter({ $0.value >= 2 }).keys.sorted() {
            let candidates = candidates(named: name, in: directories, skipped: &skipped)
            if let group = group(named: name, from: candidates) { groups.append(group) }
        }
        return CleanupPathScan(groups: groups, skippedProtected: skipped, missingDirectories: missing)
    }

    private func candidates(named name: String, in directories: [Directory], skipped: inout [String]) -> [Candidate] {
        var found: [Candidate] = []
        for directory in directories {
            for entry in directory.children where entry.url.lastPathComponent == name {
                switch entry.kind {
                case .file where entry.isExecutable:
                    if let candidate = resolve(entry, pathIndex: directory.index, skipped: &skipped) { found.append(candidate) }
                case .symlink:
                    if let candidate = resolve(entry, pathIndex: directory.index, skipped: &skipped) { found.append(candidate) }
                default:
                    continue
                }
            }
        }
        return found
    }

    /// nil when the copy is not an executable file; a candidate without a real path when the link is broken.
    private func resolve(_ entry: CleanupEntry, pathIndex: Int, skipped: inout [String]) -> Candidate? {
        do {
            let target = try fileSystem.realpath(entry.url)
            guard let resolved = try fileSystem.entry(at: target), resolved.kind == .file, resolved.isExecutable else {
                return nil
            }
            return Candidate(entry: entry, pathIndex: pathIndex, realpath: target)
        } catch CleanupFileSystemError.protectedLocation(let refused) {
            if !skipped.contains(refused) { skipped.append(refused) }
            return Candidate(entry: entry, pathIndex: pathIndex, realpath: nil)
        } catch {
            return Candidate(entry: entry, pathIndex: pathIndex, realpath: nil)
        }
    }

    private func group(named name: String, from candidates: [Candidate]) -> CleanupToolGroup? {
        var seenRealpaths: Set<String> = []
        let kept = candidates.filter { candidate in
            guard let realpath = candidate.realpath else { return true }
            return seenRealpaths.insert(realpath.path).inserted
        }
        let broken = kept.filter { $0.realpath == nil }.count
        let healthy = kept.count - broken
        guard healthy >= 2 || (healthy >= 1 && broken >= 1) else { return nil }

        var activeAssigned = false
        let copies = kept.map { candidate -> CleanupCopy in
            guard let realpath = candidate.realpath else {
                return copy(of: candidate, source: .standalone, version: nil, role: .brokenLink)
            }
            let source = classifier.classify(realpath)
            let role: CleanupCopyRole
            if source == .system {
                role = .expected
            } else if activeAssigned {
                role = .shadowed
            } else {
                activeAssigned = true
                role = .active
            }
            let version = CleanupVersionExtractor.version(fromRealpath: realpath, source: source)
            return copy(of: candidate, source: source, version: version, role: role)
        }
        return CleanupToolGroup(name: name, copies: copies)
    }

    private func copy(of candidate: Candidate, source: CleanupSource, version: String?, role: CleanupCopyRole) -> CleanupCopy {
        CleanupCopy(
            path: candidate.entry.url, realpath: candidate.realpath, pathIndex: candidate.pathIndex,
            source: source, version: version, identity: candidate.entry.identity, role: role
        )
    }
}
