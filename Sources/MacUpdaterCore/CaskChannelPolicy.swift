import Foundation

/// A cask may only own an installation when its update channel is compatible.
enum CaskChannelPolicy {
    static func permits(_ token: String, for app: ApplicationInfo) -> Bool {
        FirefoxUpdateChecker.allowsCask(token, for: app)
            && ThunderbirdInstallationChannel.permitsCask(token, for: app)
            && ZedUpdateChecker.isCompatibleCask(token, bundleIdentifier: app.bundleIdentifier)
    }

    static func applying(to app: ApplicationInfo) -> ApplicationInfo {
        guard let token = app.caskToken, !permits(token, for: app) else { return app }
        var admitted = app
        admitted.caskToken = nil
        admitted.caskMatchProvenance = nil
        admitted.isManagedByBrew = false
        return admitted
    }
}
