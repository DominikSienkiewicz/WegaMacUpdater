import Foundation

/// A handoff opens the vendor UI or its support page; it never installs an update.
public enum MicrosoftAutoUpdateHandoff {
    public static func destination(
        for app: ApplicationInfo, updaterURL: URL = MicrosoftAutoUpdateSupport.applicationURL
    ) -> URL? {
        guard MicrosoftAutoUpdateSupport.applicationID(for: app) != nil else { return nil }
        guard VendorUpdateCompletionChecker.application(at: updaterURL)?.bundleIdentifier == "com.microsoft.autoupdate2"
        else { return MicrosoftAutoUpdateSupport.supportURL }
        return updaterURL
    }
}
