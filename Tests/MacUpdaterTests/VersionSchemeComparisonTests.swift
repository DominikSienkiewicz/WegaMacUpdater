import Testing
@testable import MacUpdaterCore

/// REL-11 — the shared parser must respect each source's version semantics. The
/// same syntax means different things per source: a `-NNN` hyphen is a SemVer
/// *prerelease* for npm/GitHub (ranks below the release) but a *build number* for
/// vendors like Parallels (a later build of the same release). An unparseable
/// value must yield `.unknown`, never an arbitrary order.
@Suite("VersionScheme comparison")
struct VersionSchemeComparisonTests {

    // MARK: SemVer (npm / GitHub)

    @Test func semverPatchUpgrade() {
        #expect(compareVersions("1.2.3", "1.2.4", scheme: .semver) == .orderedAscending)
    }

    @Test func semverEqual() {
        #expect(compareVersions("2.0.0", "2.0.0", scheme: .semver) == .orderedSame)
    }

    @Test func semverDowngrade() {
        #expect(compareVersions("2.0.0", "1.9.9", scheme: .semver) == .orderedDescending)
    }

    /// A prerelease ranks below the same stable release — it must not be treated as
    /// the stable version (criterion: "Prerelease nie jest traktowany jak wersja stabilna").
    @Test func semverPrereleaseRanksBelowRelease() {
        #expect(compareVersions("1.0.0-beta", "1.0.0", scheme: .semver) == .orderedAscending)
        #expect(compareVersions("1.0.0", "1.0.0-beta", scheme: .semver) == .orderedDescending)
    }

    /// Under SemVer a numeric `-1` hyphen is a *prerelease* identifier, so it ranks
    /// below the release — the opposite of the build-numbered reading below.
    @Test func semverNumericHyphenIsPrerelease() {
        #expect(compareVersions("1.0.0-1", "1.0.0", scheme: .semver) == .orderedAscending)
    }

    @Test func semverPrereleaseOrdering() {
        #expect(compareVersions("1.0.0-alpha", "1.0.0-beta", scheme: .semver) == .orderedAscending)
    }

    /// SemVer build metadata (`+…`) does not affect precedence.
    @Test func semverBuildMetadataIgnored() {
        #expect(compareVersions("1.0.0+build.5", "1.0.0", scheme: .semver) == .orderedSame)
    }

    // MARK: Build-numbered (Sparkle / vendor / Homebrew casks)

    /// The SAME `-NNN` hyphen is a *build number* here, not a prerelease. With only
    /// one side carrying it, it is encoding noise and the versions rank equal
    /// (criterion: "Łącznik interpretowany jako numer buildu ... zgodnie z zasadami danego źródła").
    @Test func buildNumberedHyphenIsBuildNotPrerelease() {
        #expect(compareVersions("26.3.3-57507", "26.3.3", scheme: .buildNumbered) == .orderedSame)
    }

    /// When both sides carry a build number the build tier decides.
    @Test func buildNumberedBothBuildsCompared() {
        #expect(compareVersions("26.3.3-57507", "26.3.3-57600", scheme: .buildNumbered) == .orderedAscending)
    }

    /// The Zoom-style `" (NNN)"` build suffix is symmetric noise when only one side has it.
    @Test func buildNumberedParenBuildSymmetric() {
        #expect(compareVersions("7.0.0", "7.0.0 (77593)", scheme: .buildNumbered) == .orderedSame)
        #expect(compareVersions("7.0.0 (77593)", "7.0.0", scheme: .buildNumbered) == .orderedSame)
    }

    /// An *alphabetic* hyphen suffix is still a prerelease even in the build-numbered scheme.
    @Test func buildNumberedAlphaHyphenStillPrerelease() {
        #expect(compareVersions("1.0.0-beta", "1.0.0", scheme: .buildNumbered) == .orderedAscending)
    }

    @Test func buildNumberedPrimaryDecides() {
        #expect(compareVersions("26.3.2", "26.3.3-57507", scheme: .buildNumbered) == .orderedAscending)
    }

    // MARK: Unparseable ⇒ .unknown (both schemes)

    @Test func unparseableIsUnknownSemver() {
        #expect(compareVersions("89d3ad2bf", "1.0.0", scheme: .semver) == .unknown)
        #expect(compareVersions("1.0.0", "not-a-version", scheme: .semver) == .unknown)
    }

    @Test func unparseableIsUnknownBuildNumbered() {
        #expect(compareVersions("89d3ad2bf", "1.0.0", scheme: .buildNumbered) == .unknown)
        #expect(compareVersions("1.0.0", "nightly-build", scheme: .buildNumbered) == .unknown)
    }
}
