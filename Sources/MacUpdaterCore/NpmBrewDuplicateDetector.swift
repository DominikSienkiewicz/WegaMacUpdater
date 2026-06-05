import Foundation

public struct NpmBrewDuplicate: Equatable, Sendable {
    public var npmPackage: String
    public var brewToken: String

    public init(npmPackage: String, brewToken: String) {
        self.npmPackage = npmPackage
        self.brewToken = brewToken
    }
}

/// Spots packages installed via both npm-global and Homebrew. Same-named tools across
/// two package managers means duplicate disk usage and divergent versions in PATH
/// (whichever shim wins) — exactly the Codex CLI situation that started this whole thread.
///
/// Matching is intentionally simple: strip npm scope (`@openai/codex` → `codex`),
/// lowercase, then exact-compare against brew tokens. False positives are possible
/// (a `pnpm` brew formula and `pnpm` npm package legitimately ARE the same tool,
/// so flagging is correct) — false negatives (different naming conventions) are
/// acceptable; user can investigate the surfaced cases and act.
public struct NpmBrewDuplicateDetector {
    public init() { /* stateless; explicit so the initializer is public across the module boundary */ }

    public func detect(npmPackages: [NpmGlobalPackage], brewTokens: Set<String>) -> [NpmBrewDuplicate] {
        let normalizedTokens = Dictionary(uniqueKeysWithValues: brewTokens.map { (Self.normalize($0), $0) })
        var out: [NpmBrewDuplicate] = []
        for pkg in npmPackages {
            let key = Self.normalize(Self.stripScope(pkg.name))
            if let token = normalizedTokens[key] {
                out.append(NpmBrewDuplicate(npmPackage: pkg.name, brewToken: token))
            }
        }
        return out.sorted { $0.npmPackage.localizedCaseInsensitiveCompare($1.npmPackage) == .orderedAscending }
    }

    private static func stripScope(_ name: String) -> String {
        guard name.hasPrefix("@"), let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
    }
}
