import Foundation

/// Splits a version string into its variants by "," and "+" separators.
/// Homebrew uses "," and semver uses "+" for build metadata.
public func versionVariants(_ v: String) -> [String] {
    v.replacingOccurrences(of: "+", with: ",").split(separator: ",").map(String.init)
}

/// Returns numeric components from a single version segment, handling "X (Y)" → "X.Y".
public func versionComponents(_ v: String) -> [Int] {
    v.replacingOccurrences(of: " (", with: ".").replacingOccurrences(of: ")", with: "")
     .split(separator: ".").compactMap { Int($0) }
}

/// Pads two arrays to equal length with trailing zeros.
public func paddedComponents(_ a: [Int], _ b: [Int]) -> ([Int], [Int]) {
    let n = max(a.count, b.count)
    var pa = a; while pa.count < n { pa.append(0) }
    var pb = b; while pb.count < n { pb.append(0) }
    return (pa, pb)
}

/// Returns true if both version strings represent the same version.
/// Handles: "7.0.0 (77593)" vs "7.0.0.77593", "125.0" vs "125.0.0",
/// Homebrew "version,build" comma format, and semver "+" build metadata.
public func versionsEqual(_ a: String, _ b: String) -> Bool {
    let aVariants = versionVariants(a)
    let bVariants = versionVariants(b)
    for av in aVariants {
        for bv in bVariants {
            let (ca, cb) = paddedComponents(versionComponents(av), versionComponents(bv))
            if ca == cb { return true }
        }
    }
    return false
}

/// Returns true if `latest` is strictly newer than `installed`.
/// Compares the first (primary) component of each version to avoid false positives
/// from build-number suffixes.
public func isUpgrade(installed: String, latest: String) -> Bool {
    let ic = versionComponents(versionVariants(installed).first ?? installed)
    let lc = versionComponents(versionVariants(latest).first ?? latest)
    let (pi, pl) = paddedComponents(ic, lc)
    return pi.lexicographicallyPrecedes(pl)
}

/// Strips common tag prefixes/suffixes to get a clean version string.
/// "v1.12.7" → "1.12.7", "release-3.5.8" → "3.5.8", "v1.4.2-build164" → "1.4.2"
public func normalizeGitTag(_ tag: String) -> String {
    var v = tag
    for prefix in ["release-", "v", "V"] {
        if v.hasPrefix(prefix) { v = String(v.dropFirst(prefix.count)); break }
    }
    if let range = v.range(of: #"-[a-zA-Z][^.]*$"#, options: .regularExpression) {
        v = String(v[v.startIndex..<range.lowerBound])
    }
    return v
}
