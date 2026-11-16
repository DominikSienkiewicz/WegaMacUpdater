import Foundation
import WegaHelperKit

/// Decides which installed apps the Uninstall view may offer. Wega's own bundle, the
/// SIP-protected system apps and any symlinked bundle are never removable.
public enum UninstallEligibility {
    /// `symlinkDestination` returns the link's absolute, standardized destination, or `nil`
    /// when the entry is not a symlink.
    public static func protection(
        for app: ApplicationInfo,
        ownBundleIdentifier: String,
        ownBundleURL: URL,
        symlinkDestination: (URL) -> URL?
    ) -> UninstallProtection? {
        if app.bundleIdentifier == ownBundleIdentifier
            || resolved(app.path) == resolved(ownBundleURL) {
            return .wegaItself
        }
        if isUnderSystem(resolved(app.path)) { return .systemApplication }
        guard let destination = symlinkDestination(app.path) else { return nil }
        if isUnderSystem(destination) { return .systemApplication }
        return .symlink(destination: destination.standardizedFileURL.path)
    }

    public static func protections(for apps: [ApplicationInfo]) -> [String: UninstallProtection] {
        let ownURL = Bundle.main.bundleURL
        var result: [String: UninstallProtection] = [:]
        for app in apps {
            if let protection = protection(
                for: app,
                ownBundleIdentifier: WegaHelper.appBundleID,
                ownBundleURL: ownURL,
                symlinkDestination: liveSymlinkDestination
            ) {
                result[app.id] = protection
            }
        }
        return result
    }

    public static func removable(
        _ apps: [ApplicationInfo],
        protections: [String: UninstallProtection]
    ) -> [ApplicationInfo] {
        apps.filter { protections[$0.id] == nil }
    }

    private static func isUnderSystem(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return components.count > 1 && components[1] == "System"
    }

    private static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func liveSymlinkDestination(_ url: URL) -> URL? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        else { return nil }
        let base = url.deletingLastPathComponent()
        let destination = target.hasPrefix("/")
            ? URL(fileURLWithPath: target)
            : URL(fileURLWithPath: target, relativeTo: base)
        return destination.standardizedFileURL.resolvingSymlinksInPath()
    }
}
