import Foundation

/// UX-11f — turns the scanned inventory into two portable artifacts:
///
/// * a **Brewfile** (`brew bundle` manifest) that reinstalls the Homebrew casks and
///   Mac App Store apps and records everything else as comments; and
/// * a **CSV** listing every installed app and global npm package, for a spreadsheet
///   or a plain backup.
///
/// Pure and view-independent so the exact bytes written to disk are unit-tested
/// without SwiftUI or a save panel — `InventoryView` only chooses a destination and
/// writes the returned string. The file content is deliberately locale-independent
/// (English section comments, stable `Source` values): a Brewfile and a CSV are data
/// interchange, not UI chrome, and must read the same whatever language the app runs in.
public enum InventoryExport {

    // MARK: Brewfile

    /// A `brew bundle` manifest. Casks and App Store apps become installable
    /// `cask`/`mas` entries; manual apps (and anything Homebrew cannot address, such as
    /// a cask with no token) plus global npm packages are preserved as comments so the
    /// file stays a faithful record even though `brew` cannot reinstall them.
    ///
    /// Entries are de-duplicated (two copies of one app collapse to a single `cask`)
    /// and sorted so re-exporting an unchanged inventory yields an identical file.
    public static func brewfile(
        apps: [ApplicationInfo],
        npmGlobals: [NpmGlobalPackage] = []
    ) -> String {
        var lines: [String] = [
            "# Brewfile — exported by Wega (WegaMacUpdater).",
            "# Reinstall with: brew bundle --file=Brewfile",
        ]

        let casks = uniqueCaseInsensitive(
            apps.compactMap { app -> String? in
                guard AppOrigin.of(app) == .brew, let token = app.caskToken, !token.isEmpty else { return nil }
                return token
            }
        )
        if !casks.isEmpty {
            lines.append("")
            lines.append(contentsOf: casks.map { "cask \"\($0)\"" })
        }

        var seenAppStoreIDs = Set<String>()
        let masEntries = apps
            .compactMap { app -> (name: String, id: String)? in
                guard AppOrigin.of(app) == .appStore,
                      let id = app.masAppID, !id.isEmpty,
                      seenAppStoreIDs.insert(id).inserted
                else { return nil }
                return (app.name, id)
            }
            .sorted { lhs, rhs in
                let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return byName == .orderedSame ? lhs.id < rhs.id : byName == .orderedAscending
            }
        if !masEntries.isEmpty {
            lines.append("")
            lines.append(contentsOf: masEntries.map { "mas \"\(rubyEscaped($0.name))\", id: \($0.id)" })
        }

        let unmanaged = apps
            .filter { app in
                switch AppOrigin.of(app) {
                case .brew:     return (app.caskToken ?? "").isEmpty
                case .appStore: return (app.masAppID ?? "").isEmpty
                case .npm, .manual: return true
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !unmanaged.isEmpty {
            lines.append("")
            lines.append("# Installed outside Homebrew/App Store — reinstall manually:")
            lines.append(contentsOf: unmanaged.map { app in
                let version = app.version.map { " \($0)" } ?? ""
                let bundle = app.bundleIdentifier.map { " (\($0))" } ?? ""
                return "# - \(app.name)\(version)\(bundle)"
            })
        }

        if !npmGlobals.isEmpty {
            let sorted = npmGlobals.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            lines.append("")
            lines.append("# Global npm packages (npm install -g <pkg>):")
            lines.append(contentsOf: sorted.map { "# - \($0.name)@\($0.installedVersion)" })
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: CSV

    /// A spreadsheet-friendly listing of every installed app, followed by the global
    /// npm packages. RFC 4180: fields containing a comma, quote or newline are wrapped
    /// in quotes with inner quotes doubled, and rows are terminated with CRLF. Order
    /// follows the caller — the view passes the full inventory, not the filtered view.
    public static func csv(
        apps: [ApplicationInfo],
        npmGlobals: [NpmGlobalPackage] = []
    ) -> String {
        var rows: [[String]] = [["Name", "Version", "Bundle ID", "Source", "Cask", "App Store ID", "Path"]]

        for app in apps {
            rows.append([
                app.name,
                app.version ?? "",
                app.bundleIdentifier ?? "",
                sourceLabel(for: app),
                app.caskToken ?? "",
                app.masAppID ?? "",
                app.path.path,
            ])
        }
        for pkg in npmGlobals {
            rows.append([pkg.name, pkg.installedVersion, "", "npm", "", "", ""])
        }

        return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Helpers

    private static func sourceLabel(for app: ApplicationInfo) -> String {
        switch AppOrigin.of(app) {
        case .brew:         return "brew"
        case .appStore:     return "mas"
        case .npm, .manual: return "manual"
        }
    }

    /// First-seen order preserved, then sorted case-insensitively — case-only duplicate
    /// tokens (never emitted by the scanner, but cheap to guard) collapse to one line.
    private static func uniqueCaseInsensitive(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Escapes a value for a Ruby double-quoted string so a display name containing a
    /// quote or backslash cannot break the `mas "…"` line's syntax.
    private static func rubyEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
