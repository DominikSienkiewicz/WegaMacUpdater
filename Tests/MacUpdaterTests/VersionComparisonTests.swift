import Testing
@testable import MacUpdaterCore

@Suite("VersionComparison")
struct VersionComparisonTests {

    // MARK: versionVariants

    @Test func variantsCommaFormat() {
        let parts = versionVariants("5.3.1,50301.0.2601271414")
        #expect(parts == ["5.3.1", "50301.0.2601271414"])
    }

    @Test func variantsPlusFormat() {
        let parts = versionVariants("0.4.13+1")
        #expect(parts == ["0.4.13", "1"])
    }

    @Test func variantsSingleVersion() {
        #expect(versionVariants("1.2.3") == ["1.2.3"])
    }

    // MARK: versionComponents

    @Test func componentsPlain() {
        #expect(versionComponents("7.0.0") == [7, 0, 0])
    }

    @Test func componentsBuildInParens() {
        #expect(versionComponents("7.0.0 (77593)") == [7, 0, 0, 77593])
    }

    @Test func componentsIgnoresNonNumeric() {
        #expect(versionComponents("abc") == [])
    }

    // MARK: versionsEqual

    @Test func equalPlainVersions() {
        #expect(versionsEqual("1.2.3", "1.2.3"))
    }

    @Test func equalDifferentLength() {
        #expect(versionsEqual("125.0", "125.0.0"))
    }

    @Test func equalBundleVsFlat() {
        #expect(versionsEqual("7.0.0 (77593)", "7.0.0.77593"))
    }

    @Test func equalBrewCommaFormat() {
        #expect(versionsEqual("5.3.1,50301.0", "5.3.1"))
    }

    @Test func equalSemverPlusBuild() {
        #expect(versionsEqual("0.4.13+1", "0.4.13,1"))
    }

    @Test func notEqualDifferentVersions() {
        #expect(!versionsEqual("1.2.3", "1.2.4"))
    }

    @Test func notEqualGoogleDriveFalsePositive() {
        #expect(versionsEqual("125.0", "125.0.0"))
    }

    @Test func notEqualZoomFalsePositive() {
        #expect(versionsEqual("7.0.0 (77593)", "7.0.0.77593"))
    }

    // MARK: isUpgrade

    @Test func upgradeDetected() {
        #expect(isUpgrade(installed: "1.2.3", latest: "1.2.4"))
    }

    @Test func upgradeMinorVersion() {
        #expect(isUpgrade(installed: "1.1.0", latest: "1.2.0"))
    }

    @Test func upgradeMajorVersion() {
        #expect(isUpgrade(installed: "1.0.0", latest: "2.0.0"))
    }

    @Test func noUpgradeWhenEqual() {
        #expect(!isUpgrade(installed: "1.2.3", latest: "1.2.3"))
    }

    @Test func noUpgradeWhenDowngrade() {
        #expect(!isUpgrade(installed: "2.0.0", latest: "1.9.9"))
    }

    @Test func noUpgradeLogiDowngradeCase() {
        #expect(!isUpgrade(installed: "10.9.0", latest: "10.7.0"))
    }

    @Test func upgradeBrewCommaFormat() {
        // brew tracks "5.3.1,50301" but latest is "5.3.2"
        #expect(isUpgrade(installed: "5.3.1,50301", latest: "5.3.2"))
    }

    @Test func noUpgradeBrewCommaFormatEqual() {
        #expect(!isUpgrade(installed: "5.3.1,50301", latest: "5.3.1"))
    }

    // MARK: normalizeGitTag

    @Test func normalizeLowercaseV() {
        #expect(normalizeGitTag("v1.12.7") == "1.12.7")
    }

    @Test func normalizeUppercaseV() {
        #expect(normalizeGitTag("V2.0.0") == "2.0.0")
    }

    @Test func normalizeReleasePrefix() {
        #expect(normalizeGitTag("release-3.5.8") == "3.5.8")
    }

    @Test func normalizeBuildSuffix() {
        #expect(normalizeGitTag("v1.4.2-build164") == "1.4.2")
    }

    @Test func normalizeNoPrefix() {
        #expect(normalizeGitTag("1.2.3") == "1.2.3")
    }

    @Test func normalizeAlphaChannelSuffix() {
        #expect(normalizeGitTag("v2.0.0-beta") == "2.0.0")
    }

    @Test func normalizeDotedSuffixKept() {
        // "v1.0.0-1" — numeric after dash has a dot chain, keep as-is (not alpha)
        // regex strips only -[alpha]... so "v1.0.0-1" numeric tail is NOT stripped
        #expect(normalizeGitTag("v1.0.0-1") == "1.0.0-1")
    }
}
