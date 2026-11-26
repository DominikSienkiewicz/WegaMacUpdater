import Darwin
import Foundation

/// A physical scan supplies the displayed size and the comparison made before moving a cache to the Trash.
struct XcodeCleanupTree: Hashable, Sendable {
    var allocatedBytes: Int64 = 0
    var lastModified: Date = .distantPast
    var hasOnlyCacheContents = true
    private var fingerprint = 0
    private var count = 0

    private static let cacheContents: Set<String> = [
        "info.plist", "Build", "Logs", "Index", "Index.noindex", "SourcePackages", "ModuleCache.noindex",
        "SDKStatCaches.noindex", "CompilationCache.noindex", "TextIndex", "SymbolCache", ".DS_Store",
    ]

    static func measure(_ root: CleanupEntry) throws -> Self {
        guard let path = strdup(root.url.path) else { throw POSIXError(.ENOMEM) }
        defer { free(path) }
        var arguments = [Optional(path), nil]
        guard let tree = arguments.withUnsafeMutableBufferPointer({
            fts_open($0.baseAddress, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil)
        }) else { throw CocoaError(.fileReadUnknown) }
        defer { fts_close(tree) }

        let checkouts = root.url.appending(path: "SourcePackages/checkouts", directoryHint: .isDirectory)
        var result = Self()
        var hardLinks = Set<ino_t>()
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let node = fts_read(tree) else {
                guard errno == 0 else { throw CocoaError(.fileReadUnknown) }
                return result
            }
            let info = Int32(node.pointee.fts_info)
            if info == FTS_DP { continue }
            guard info != FTS_DNR, info != FTS_ERR, info != FTS_NS, info != FTS_DC,
                  let status = node.pointee.fts_statp?.pointee,
                  UInt64(UInt32(bitPattern: status.st_dev)) == root.identity.device else {
                throw CocoaError(.fileReadUnknown)
            }
            if node.pointee.fts_level == 0 {
                guard info == FTS_D, UInt64(status.st_ino) == root.identity.inode else { throw CocoaError(.fileReadUnknown) }
            } else if node.pointee.fts_level == 1, info != FTS_SL, info != FTS_SLNONE {
                let name = URL(filePath: String(cString: node.pointee.fts_path), directoryHint: .notDirectory).lastPathComponent
                if !cacheContents.contains(name) { result.hasOnlyCacheContents = false }
            } else if info == FTS_D, node.pointee.fts_level == 3 {
                let directory = URL(filePath: String(cString: node.pointee.fts_path), directoryHint: .isDirectory)
                if directory.deletingLastPathComponent().path.caseInsensitiveCompare(checkouts.path) == .orderedSame {
                    result.hasOnlyCacheContents = false
                }
            }
            let countsTowardSize = info != FTS_F || status.st_nlink <= 1 || hardLinks.insert(status.st_ino).inserted
            result.record(status, countsTowardSize: countsTowardSize)
        }
    }

    private mutating func record(_ status: stat, countsTowardSize: Bool) {
        if countsTowardSize { allocatedBytes += Int64(status.st_blocks) * 512 }
        let modified = status.st_mtimespec
        let date = Date(timeIntervalSince1970: TimeInterval(modified.tv_sec) + TimeInterval(modified.tv_nsec) / 1_000_000_000)
        lastModified = max(lastModified, date)
        // fts may return siblings in a different order after a new scan.
        var hash = Hasher()
        hash.combine(status.st_ino)
        hash.combine(status.st_mode)
        hash.combine(status.st_size)
        hash.combine(modified.tv_sec)
        hash.combine(modified.tv_nsec)
        hash.combine(status.st_ctimespec.tv_sec)
        hash.combine(status.st_ctimespec.tv_nsec)
        fingerprint ^= hash.finalize()
        count += 1
    }
}
