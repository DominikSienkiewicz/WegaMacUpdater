import Foundation

/// Office installations eligible for the vendor-owned Microsoft AutoUpdate flow.
public enum MicrosoftAutoUpdateSupport {
    public static let sourceLabel = "Microsoft AutoUpdate"
    public static let applicationURL = URL(fileURLWithPath:
        "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app")
    public static let supportURL = URL(string:
        "https://support.microsoft.com/en-us/office/lifecycle/officeinstall/update-office-for-mac-automatically")!

    public static func applicationID(for app: ApplicationInfo) -> String? {
        guard !app.isManagedByMas, app.masAppID == nil,
              !FileManager.default.fileExists(atPath: app.path.appendingPathComponent("Contents/_MASReceipt/receipt").path),
              let bundleID = app.bundleIdentifier else { return nil }
        return applicationID(bundleIdentifier: bundleID)
    }

    static func applicationID(bundleIdentifier: String) -> String? {
        [
            "com.microsoft.Word": "MSWD2019",
            "com.microsoft.Excel": "XCEL2019",
            "com.microsoft.Powerpoint": "PPT32019",
            "com.microsoft.Outlook": "OPIM2019",
            "com.microsoft.onenote.mac": "ONMC2019",
        ][bundleIdentifier]
    }
}
