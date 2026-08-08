import Foundation

/// Adobe's desktop client, as something to launch rather than a page to visit.
///
/// Creative Cloud is the only thing that installs an Adobe update, so when it is on the
/// machine the row should open *it* — the same relationship JetBrains Toolbox has with its
/// IDEs. The web page is the fallback for a machine that does not have it, not the
/// destination.
///
/// Resolution goes through the bundle identifier rather than a path, and the reason is
/// concrete: Creative Cloud does not install into `/Applications`. On a stock install the
/// app sits at `/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app`, three
/// levels down and under a different name than the folder Adobe puts in `/Applications`, so
/// a candidate-path list would miss it on exactly the machines that have it.
public enum CreativeCloudApplication {
    /// Adobe's desktop client bundle identifiers, most preferred first.
    ///
    /// `com.adobe.acc.AdobeCreativeCloud` is the client with the Updates list — the window a
    /// user needs to be looking at. `com.adobe.Creative-Cloud-Desktop-App` ships beside it as
    /// the launcher shim; opening it reaches the same client the long way round, so it is a
    /// fallback rather than an equal.
    public static let bundleIdentifiers = [
        "com.adobe.acc.AdobeCreativeCloud",
        "com.adobe.Creative-Cloud-Desktop-App",
    ]

    /// The installed Creative Cloud, or `nil` when Adobe's client is not on this machine.
    ///
    /// `lookup` is a parameter so the preference order is unit-tested without LaunchServices;
    /// production passes `NSWorkspace.urlForApplication(withBundleIdentifier:)`.
    public static func resolve(using lookup: (String) -> URL?) -> URL? {
        for identifier in bundleIdentifiers {
            if let url = lookup(identifier) { return url }
        }
        return nil
    }
}
