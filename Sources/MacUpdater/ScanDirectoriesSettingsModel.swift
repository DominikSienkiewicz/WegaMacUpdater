import Foundation
import MacUpdaterCore
import SwiftUI

/// UX-16 — observable state for configurable scan directories, exclusions and recursion
/// depth. It edits `UserDefaults` through `ScanConfigurationStore`; scan seams read the same
/// keys, so a change takes effect on the next scan.
@MainActor
final class ScanDirectoriesSettingsModel: ObservableObject {
    @Published private(set) var userDirectories: [URL] = []
    @Published private(set) var exclusions: [URL] = []
    @Published private(set) var recursionDepth: Int = ScanConfiguration.defaultRecursionDepth

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    func reload() {
        userDirectories = ScanConfigurationStore.resolvedUserDirectories(from: defaults)
        exclusions = ScanConfigurationStore.exclusionPaths(from: defaults)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        recursionDepth = ScanConfigurationStore.recursionDepth(from: defaults)
    }

    func addUserDirectory(_ url: URL) {
        ScanConfigurationStore.addUserDirectory(url, to: defaults)
        reload()
    }

    func removeUserDirectory(_ url: URL) {
        ScanConfigurationStore.removeUserDirectory(
            resolvedPath: url.resolvingSymlinksInPath().path,
            from: defaults
        )
        reload()
    }

    func addExclusion(_ url: URL) {
        ScanConfigurationStore.addExclusion(url, to: defaults)
        reload()
    }

    func removeExclusion(_ url: URL) {
        ScanConfigurationStore.removeExclusion(
            path: url.standardizedFileURL.path,
            from: defaults
        )
        reload()
    }

    func setRecursionDepth(_ depth: Int) {
        ScanConfigurationStore.setRecursionDepth(depth, in: defaults)
        recursionDepth = ScanConfigurationStore.recursionDepth(from: defaults)
    }
}
