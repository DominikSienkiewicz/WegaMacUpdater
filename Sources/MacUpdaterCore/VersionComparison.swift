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

// MARK: - Per-source version semantics (REL-11)

/// The ordering of two version strings under a source's rules. `.unknown` is a
/// first-class result: an unparseable value (e.g. a git hash "version") must never
/// be forced into an arbitrary position — it is genuinely incomparable, exactly as
/// `versionChangeKind` already returns `.unknown` rather than lying.
public enum VersionOrder: Equatable, Sendable {
    case orderedAscending   // a < b
    case orderedSame        // a ≈ b
    case orderedDescending  // a > b
    case unknown            // at least one side is not a parseable version
}

/// How a source encodes its version strings. The same syntax means opposite things
/// per source, which is why one shared tolerant parser was wrong: a `-NNN` hyphen is
/// a SemVer *prerelease* for npm and GitHub (ranking *below* the release), but a
/// *build number* for vendors like Parallels (a later build of the same release).
public enum VersionScheme: Sendable {
    /// Strict SemVer 2.0.0 — npm and GitHub. `X.Y.Z-prerelease+build`. A prerelease
    /// ranks below the same release; build metadata (`+…`) never affects precedence.
    case semver
    /// The tolerant vendor/Sparkle/Homebrew scheme. A numeric `-NNN`, `" (NNN)"`,
    /// `,NNN` or `+NNN` suffix is a *build number* — a secondary tier that only breaks
    /// a tie when BOTH versions carry one (otherwise it is encoding noise). An
    /// alphabetic `-beta`/`-rc` suffix is still a prerelease and ranks below the release.
    case buildNumbered
}

/// A version decomposed for comparison: the numeric `primary` core, an optional
/// SemVer-style `prerelease` (ranking below the same release), and a numeric `build`
/// tier that only breaks a tie when both sides carry one.
private struct ParsedVersion {
    var primary: [Int]
    var prerelease: [String]   // empty ⇒ no prerelease (stable)
    var build: [Int]           // empty ⇒ no build number
    var hasPrerelease: Bool { !prerelease.isEmpty }
}

private func parseVersion(_ v: String, scheme: VersionScheme) -> ParsedVersion? {
    switch scheme {
    case .semver:        return parseSemver(v)
    case .buildNumbered: return parseBuildNumbered(v)
    }
}

/// Strict SemVer parse: `major.minor.patch[-prerelease][+build]`. Build metadata is
/// dropped (it does not affect precedence). Returns `nil` when there is no numeric core.
private func parseSemver(_ v: String) -> ParsedVersion? {
    let trimmed = v.trimmingCharacters(in: .whitespaces)
    let core = trimmed.split(separator: "+", maxSplits: 1).first.map(String.init) ?? trimmed
    let mainAndPre = core.split(separator: "-", maxSplits: 1).map(String.init)
    let mainPart = mainAndPre.first ?? core
    let primary = mainPart.split(separator: ".").compactMap { Int($0) }
    guard !primary.isEmpty else { return nil }
    let prerelease = mainAndPre.count > 1 ? mainAndPre[1].split(separator: ".").map(String.init) : []
    return ParsedVersion(primary: primary, prerelease: prerelease, build: [])
}

/// Tolerant vendor parse. Splits off build numbers from the `,`/`+` variants, the
/// Zoom-style `" (NNN)"` suffix, and a trailing numeric `-NNN`; an alphabetic `-beta`
/// suffix is a prerelease. Returns `nil` when there is no numeric core.
private func parseBuildNumbered(_ v: String) -> ParsedVersion? {
    let variants = versionVariants(v)          // splits on "," and "+"
    var build: [Int] = []
    if variants.count > 1 {
        build += variants[1...].flatMap { $0.split(separator: ".").compactMap { Int($0) } }
    }

    var coreString = variants.first ?? v
    // Zoom-style " (NNN)" build suffix.
    if let paren = coreString.range(of: #" \(\d+\)"#, options: .regularExpression) {
        let digits = coreString[paren].drop { !$0.isNumber }.prefix { $0.isNumber }
        if let n = Int(digits) { build.append(n) }
        coreString.removeSubrange(paren)
    }

    // Trailing dash suffix: numeric ⇒ build number, alphabetic ⇒ prerelease.
    var prerelease: [String] = []
    if let dash = coreString.firstIndex(of: "-") {
        let suffix = String(coreString[coreString.index(after: dash)...])
        coreString = String(coreString[..<dash])
        if let n = Int(suffix) {
            build.append(n)
        } else if suffix.first?.isLetter == true {
            prerelease = suffix.split(separator: ".").map(String.init)
        } else {
            build += suffix.split(separator: ".").compactMap { Int($0) }
        }
    }

    let primary = coreString.split(separator: ".").compactMap { Int($0) }
    guard !primary.isEmpty else { return nil }
    return ParsedVersion(primary: primary, prerelease: prerelease, build: build)
}

private func comparePrerelease(_ a: [String], _ b: [String]) -> VersionOrder? {
    let n = max(a.count, b.count)
    for i in 0..<n {
        // With an equal prefix, more identifiers ranks higher (SemVer §11).
        guard i < a.count else { return .orderedAscending }
        guard i < b.count else { return .orderedDescending }
        let ai = a[i], bi = b[i]
        switch (Int(ai), Int(bi)) {
        case let (an?, bn?):
            if an != bn { return an < bn ? .orderedAscending : .orderedDescending }
        case (_?, nil):
            return .orderedAscending    // numeric identifiers rank below alphanumeric
        case (nil, _?):
            return .orderedDescending
        case (nil, nil):
            if ai != bi { return ai < bi ? .orderedAscending : .orderedDescending }
        }
    }
    return nil
}

private func compare(_ a: ParsedVersion, _ b: ParsedVersion) -> VersionOrder {
    let (pi, pl) = paddedComponents(a.primary, b.primary)
    if pi != pl { return pi.lexicographicallyPrecedes(pl) ? .orderedAscending : .orderedDescending }
    // A prerelease ranks below the same stable release.
    switch (a.hasPrerelease, b.hasPrerelease) {
    case (false, true):  return .orderedDescending
    case (true, false):  return .orderedAscending
    case (true, true):   if let order = comparePrerelease(a.prerelease, b.prerelease) { return order }
    case (false, false): break
    }
    // Build tier decides only when BOTH sides carry a build number; otherwise it is noise.
    if !a.build.isEmpty, !b.build.isEmpty {
        let (bi, bl) = paddedComponents(a.build, b.build)
        if bi != bl { return bi.lexicographicallyPrecedes(bl) ? .orderedAscending : .orderedDescending }
    }
    return .orderedSame
}

/// Orders two version strings under a specific source's `scheme`. Unparseable input
/// yields `.unknown` rather than an arbitrary order (REL-11).
public func compareVersions(_ a: String, _ b: String, scheme: VersionScheme) -> VersionOrder {
    guard let pa = parseVersion(a, scheme: scheme), let pb = parseVersion(b, scheme: scheme) else {
        return .unknown
    }
    return compare(pa, pb)
}

/// Returns true if `latest` is strictly newer than `installed` under the default
/// build-numbered scheme. Unparseable input is gated to `false` (the same guard
/// `versionChangeKind` applies), and a build-number suffix present on only one side
/// is treated as noise, so `"7.0.0"` vs `"7.0.0 (77593)"` is not a phantom upgrade.
public func isUpgrade(installed: String, latest: String) -> Bool {
    isUpgrade(installed: installed, latest: latest, scheme: .buildNumbered)
}

/// Scheme-aware upgrade check: npm and GitHub pass `.semver`, everything else uses
/// the tolerant `.buildNumbered` default.
public func isUpgrade(installed: String, latest: String, scheme: VersionScheme) -> Bool {
    compareVersions(installed, latest, scheme: scheme) == .orderedAscending
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

/// How a version target should be emphasised in the UI. UI-agnostic (no colour) so
/// it stays in Core and is unit-tested; the view layer maps it to a colour.
public enum VersionEmphasisKind: Equatable {
    case normal, major, security, forced
}

/// Picks the emphasis for a version target. Security fixes win over a forced/`--force`
/// update, which wins over a plain major bump; everything else is normal.
public func versionEmphasis(changeKind: VersionChangeKind,
                            isSecurityFix: Bool,
                            requiresForce: Bool) -> VersionEmphasisKind {
    if isSecurityFix { return .security }
    if requiresForce { return .forced }
    if changeKind == .major { return .major }
    return .normal
}
