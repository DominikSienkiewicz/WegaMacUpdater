import Foundation

/// One side of an npm↔brew duplicate the user chose to remove. Pure value type:
/// it knows the command it represents and the busy-key the UI uses to disable the
/// right button. Lives in Core (not the view) so the command preview is unit-tested.
public struct DuplicateRemoval: Identifiable, Equatable, Sendable {
    public enum Side: Equatable, Sendable { case npm, brew }
    public let dup: NpmBrewDuplicate
    public let side: Side

    public init(dup: NpmBrewDuplicate, side: Side) {
        self.dup = dup
        self.side = side
    }

    public var id: String { busyKey }

    public var busyKey: String {
        switch side {
        case .npm:  return "npm:\(dup.npmPackage)"
        case .brew: return "brew:\(dup.brewToken)"
        }
    }

    public var commandPreview: String {
        switch side {
        case .npm:  return "npm uninstall -g \(dup.npmPackage)"
        case .brew: return "brew uninstall \(dup.brewToken)"
        }
    }
}

/// Pure, view-independent logic for the Migration screen. Extracted out of
/// `MigrationView` so candidate partitioning and leftover-path construction can be
/// unit-tested without SwiftUI or a real filesystem.
public enum MigrationPlanner {
    /// Apps that have a Homebrew cask equivalent and haven't been migrated yet.
    public static func matchable(candidates: [ApplicationInfo], migrated: Set<String>) -> [ApplicationInfo] {
        candidates.filter { app in
            guard let token = app.caskToken else { return false }
            return !migrated.contains(token)
        }
    }

    /// Apps with neither a Homebrew cask match nor an App Store candidate.
    public static func unmatched(candidates: [ApplicationInfo], masAppIDs: Set<String>) -> [ApplicationInfo] {
        candidates.filter { $0.caskToken == nil && !masAppIDs.contains($0.id) }
    }

    /// The migration pool excludes apps already managed by Homebrew or the App Store.
    public static func migrationPool(_ apps: [ApplicationInfo]) -> [ApplicationInfo] {
        apps.filter { !$0.isManagedByBrew && !$0.isManagedByMas }
    }

    /// The `~/Library` locations a freshly-migrated app may have left behind. Pure path
    /// construction; the caller filters these by existence on disk.
    public static func libraryLeftoverCandidates(bundleId: String, home: URL) -> [URL] {
        let lib = home.appendingPathComponent("Library")
        return [
            lib.appendingPathComponent("Application Support/\(bundleId)"),
            lib.appendingPathComponent("Preferences/\(bundleId).plist"),
            lib.appendingPathComponent("Caches/\(bundleId)"),
            lib.appendingPathComponent("Saved Application State/\(bundleId).savedState"),
            lib.appendingPathComponent("Containers/\(bundleId)"),
        ]
    }
}
