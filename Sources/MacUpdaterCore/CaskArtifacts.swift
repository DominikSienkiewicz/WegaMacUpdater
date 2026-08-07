import Foundation

/// A JSON value decoded structurally.
///
/// Homebrew's `artifacts` array is genuinely heterogeneous — `{"app": ["Foo.app"]}`,
/// `{"pkg": [...]}`, `{"uninstall": [{"pkgutil": "…", "launchctl": [...]}]}`, `{"zap": …}` —
/// so no `Codable` model describes it without either enumerating Homebrew's whole artifact
/// vocabulary or throwing on the first stanza it has not seen. This walks the shape instead
/// of modelling it, which keeps a new artifact kind upstream from breaking the cask database
/// download for everyone.
enum JSONValue: Decodable, Equatable {
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    /// Numbers, booleans and null — present in the payload, never on a path we read.
    case scalar

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .scalar
        }
    }

    /// The strings at this value, whether it is a single string or an array of them —
    /// Homebrew writes both spellings for the same stanza.
    var strings: [String] {
        switch self {
        case .string(let value):  return [value]
        case .array(let values):  return values.flatMap(\.strings)
        case .object, .scalar:    return []
        }
    }
}

/// Extracts the installer-package identifiers a cask claims.
enum CaskArtifacts {
    /// Reads `uninstall` → `pkgutil` only.
    ///
    /// `zap` also carries `pkgutil` entries, but they are the aggressive leftover sweep and
    /// are routinely written as wildcards (`com.vendor.*`), which would map a whole vendor
    /// namespace onto one token. `uninstall` names the packages the cask actually installed,
    /// so only exact identifiers are taken and a wildcard is dropped rather than matched
    /// loosely — a wrong token here would offer the user the wrong update.
    static func uninstallPackageIdentifiers(in artifacts: [JSONValue]) -> [String] {
        artifacts
            .compactMap { artifact -> [JSONValue]? in
                guard case .object(let stanzas) = artifact,
                      case .array(let uninstalls)? = stanzas["uninstall"] else { return nil }
                return uninstalls
            }
            .flatMap { $0 }
            .flatMap { uninstall -> [String] in
                guard case .object(let directives) = uninstall,
                      let pkgutil = directives["pkgutil"] else { return [] }
                return pkgutil.strings
            }
            .filter { !$0.contains("*") && !$0.isEmpty }
    }
}
