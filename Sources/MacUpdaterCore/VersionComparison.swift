import Foundation

/// Splits a version string into its variants by "," and "+" separators.
/// Homebrew uses "," and semver uses "+" for build metadata.
public func versionVariants(_ v: String) -> [String] {
    v.replacingOccurrences(of: "+", with: ",").split(separator: ",").map(String.init)
}

/// Returns numeric components from a single version segment. Handles:
/// - "X (Y)" → "X.Y" (Zoom-style)
/// - "X.Y.Z-build" → "X.Y.Z.build" (Parallels-style; the `-NNNNN` suffix is
///   the build number, not a pre-release tag — without this, `26.3.3-57507`
///   parsed only as `[26, 3]` and the drift filter wrongly hid Parallels
///   from the outdated list).
public func versionComponents(_ v: String) -> [Int] {
    v.replacingOccurrences(of: " (", with: ".")
     .replacingOccurrences(of: ")", with: "")
     .replacingOccurrences(of: "-", with: ".")
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

/// Returns true if `candidate` is at least as new as `baseline`, treating the
/// build-metadata segment (after "+" or ",") as significant **only when both
/// versions carry one**. Used for Homebrew cask drift detection.
///
/// This distinguishes the on-disk `0.4.16+1` from the cask's `0.4.16,2` — both
/// carry a build segment, so `1 < 2` means the app is genuinely behind and must
/// not be hidden as drift — while still treating a bare on-disk `5.3.1` as equal
/// to Homebrew's `5.3.1,50301` (only one side has a build segment, so it is
/// encoding noise rather than a real difference). `versionsEqual` cannot make
/// this distinction because it matches any variant against any variant, so the
/// primary `0.4.16` always collides regardless of the build segment.
public func versionAtLeast(_ candidate: String, _ baseline: String) -> Bool {
    let cv = versionVariants(candidate)
    let bv = versionVariants(baseline)
    let (cPrimary, bPrimary) = paddedComponents(
        versionComponents(cv.first ?? candidate),
        versionComponents(bv.first ?? baseline)
    )
    if cPrimary != bPrimary {
        return bPrimary.lexicographicallyPrecedes(cPrimary)
    }
    // Primaries equal — the build segment decides, but only when both sides have one.
    guard cv.count > 1, bv.count > 1 else { return true }
    let (cBuild, bBuild) = paddedComponents(versionComponents(cv[1]), versionComponents(bv[1]))
    return !cBuild.lexicographicallyPrecedes(bBuild)
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

/// The semantic size of a version bump, from the first component that differs.
public enum VersionChangeKind: Equatable {
    case major, minor, patch, same, unknown
}

/// Classifies `installed` → `latest` as a major/minor/patch bump. Reuses the same
/// tolerant parsing as `isUpgrade` (Zoom "X (Y)", Parallels "X-build", padding), so
/// unparseable inputs (e.g. a git-hash "version") return `.unknown` rather than lying.
public func versionChangeKind(from installed: String, to latest: String) -> VersionChangeKind {
    let ic = versionComponents(versionVariants(installed).first ?? installed)
    let lc = versionComponents(versionVariants(latest).first ?? latest)
    guard !ic.isEmpty, !lc.isEmpty else { return .unknown }
    let (pi, pl) = paddedComponents(ic, lc)
    for i in pi.indices where pi[i] != pl[i] {
        switch i {
        case 0:  return .major
        case 1:  return .minor
        default: return .patch
        }
    }
    return .same
}
