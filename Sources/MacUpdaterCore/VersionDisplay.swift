import Foundation

/// How a version pair is shown on one line of a row. The full strings stay available in
/// tooltips and the inspector.
public enum VersionDisplay {
    private static let shortTagLength = 7

    /// The readable short form of `from` and `to`: the versions without Homebrew's `,<build>`
    /// or a trailing ` (<build>)`, and the build kept (shortened) only when it is the sole
    /// difference. Empty strings and `"—"` pass through unchanged.
    public static func pair(from: String, to: String) -> (from: String, to: String) {
        let lhs = split(from)
        let rhs = split(to)
        guard lhs.main == rhs.main, from != to else { return (lhs.main, rhs.main) }
        return (withTag(lhs), withTag(rhs))
    }

    private static func split(_ version: String) -> (main: String, tag: String?) {
        if let comma = version.firstIndex(of: ",") {
            return (String(version[..<comma]), String(version[version.index(after: comma)...]))
        }
        if version.hasSuffix(")"), let open = version.range(of: " (", options: .backwards) {
            let tag = version[open.upperBound...].dropLast()
            return (String(version[..<open.lowerBound]), String(tag))
        }
        return (version, nil)
    }

    private static func withTag(_ parts: (main: String, tag: String?)) -> String {
        guard let tag = parts.tag, !tag.isEmpty else { return parts.main }
        return "\(parts.main) (\(tag.prefix(shortTagLength)))"
    }
}
