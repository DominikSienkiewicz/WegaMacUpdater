import Foundation

/// Read-only filesystem measurements used by the download resource gate.
public enum DiskResourceProbe {
    /// Capacity available for an important user-initiated operation on the volume where
    /// snapshots are created. Returning `nil` is a hard-gate result, never an implicit pass.
    public static func availableBytes(at url: URL = FileManager.default.temporaryDirectory) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// Conservative full-copy estimate for rollback snapshots. APFS clones initially use
    /// less space, but budgeting the allocated bytes also covers copy-on-write divergence.
    public static func snapshotBytes(appURLs: [URL]) -> Int64 {
        Set(appURLs.map(\.standardizedFileURL.path))
            .map { allocatedBytes(at: URL(fileURLWithPath: $0)) }
            .reduce(0, saturatingAdd)
    }

    private static func allocatedBytes(at root: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return fileBytes(at: root, keys: keys)
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            total = saturatingAdd(total, fileBytes(at: url, keys: keys))
        }
        return total
    }

    private static func fileBytes(at url: URL, keys: Set<URLResourceKey>) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return 0 }
        return Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}
