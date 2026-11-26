import Foundation

public struct InventoryFootprintChange: Equatable, Sendable {
    public let bundleBytes: Int64?
    public let cacheBytes: Int64?
    public let dataBytes: Int64?
    public let totalBytes: Int64?

    fileprivate init(from previous: InventoryFootprint, to current: InventoryFootprint) {
        func difference(_ before: Int64?, _ after: Int64?) -> Int64? {
            guard let before, let after, before >= 0, after >= 0 else { return nil }
            return after - before
        }
        bundleBytes = difference(previous.bundleBytes, current.bundleBytes)
        let libraryComparable = previous.includesLibrary && current.includesLibrary
        cacheBytes = libraryComparable ? difference(previous.cacheBytes, current.cacheBytes) : nil
        dataBytes = libraryComparable ? difference(previous.dataBytes, current.dataBytes) : nil
        totalBytes = previous.includesLibrary == current.includesLibrary ? difference(previous.totalBytes, current.totalBytes) : nil
    }
}

public struct InventoryFootprintMeasurement: Sendable {
    public let readAt: Date
    public let previousDate: Date?
    public let sizes: [InstallationIdentity: InventoryFootprint]
    public let changes: [InstallationIdentity: InventoryFootprintChange]
    public let saved: Bool
}

/// Remembers one completed inventory measurement locally. Revisiting a read reuses its
/// comparison, so opening the size column twice cannot replace a useful delta with zero.
public actor InventoryFootprintHistory {
    public static let shared = InventoryFootprintHistory(fileURL: FileScanSnapshotIO.defaultFileURL
        .deletingLastPathComponent().appending(component: "inventory-footprints.json"))

    private struct Entry: Codable {
        let bundleID: String?
        let size: InventoryFootprint
    }

    private struct Snapshot: Codable {
        let measuredAt: Date
        let entries: [String: Entry]
    }

    private let file: FileScanSnapshotIO
    private var lastSnapshot: Snapshot?
    private var lastReport: InventoryFootprintMeasurement?

    public init(fileURL: URL) { file = FileScanSnapshotIO(fileURL: fileURL) }

    public func record(_ sizes: [InstallationIdentity: InventoryFootprint], apps: [ApplicationInfo], readAt: Date,
                       measuredAt: Date = .now) throws -> InventoryFootprintMeasurement {
        try Task.checkCancellation()
        if let lastReport, lastReport.readAt == readAt { return lastReport }

        let previous = lastSnapshot ?? load()
        var changes: [InstallationIdentity: InventoryFootprintChange] = [:]
        var entries: [String: Entry] = [:]
        for app in apps {
            let key = app.installation
            guard let size = sizes[key] else { continue }
            let identifier = app.bundleIdentifier?.lowercased()
            entries[key.rawValue] = Entry(bundleID: identifier, size: size)
            if let identifier, !identifier.isEmpty, let old = previous?.entries[key.rawValue], identifier == old.bundleID {
                changes[key] = InventoryFootprintChange(from: old.size, to: size)
            }
        }
        let snapshot = Snapshot(measuredAt: measuredAt, entries: entries)
        try Task.checkCancellation()
        var saved = true
        do { try file.write(JSONEncoder().encode(snapshot)) } catch { saved = false }
        lastSnapshot = snapshot
        let report = InventoryFootprintMeasurement(readAt: readAt, previousDate: previous?.measuredAt,
                                                   sizes: sizes, changes: changes, saved: saved)
        lastReport = report
        return report
    }

    private func load() -> Snapshot? {
        guard let data = try? file.read() else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
