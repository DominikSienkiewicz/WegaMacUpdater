import Foundation

public enum CaskDisplayName {
    /// The installed bundle's file name without ".app"; the token when there is no path or the name would be empty.
    public static func name(token: String, appPath: URL?) -> String {
        guard let name = appPath?.deletingPathExtension().lastPathComponent,
              !name.isEmpty, name != "/" else { return token }
        return name
    }
}
