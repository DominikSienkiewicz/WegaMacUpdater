import Foundation

public enum CaskDisplayName {
    /// The installed bundle's file name without ".app"; the token when there is no path or the name would be empty.
    public static func name(token: String, appPath: URL?) -> String {
        guard let name = appPath?.deletingPathExtension().lastPathComponent,
              !name.isEmpty, name != "/" else { return token }
        return name
    }

    /// One label per cask, in order: the display name, or "name (token)" when another cask in the
    /// same list shares that name (a stable and a beta build of one app).
    public static func labels(for casks: [(token: String, appPath: URL?)]) -> [String] {
        let names = casks.map { name(token: $0.token, appPath: $0.appPath) }
        return zip(casks, names).map { cask, name in
            names.filter { $0 == name }.count > 1 && cask.token != name ? "\(name) (\(cask.token))" : name
        }
    }
}
