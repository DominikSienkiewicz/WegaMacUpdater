import Testing
import Foundation
@testable import MacUpdaterCore

/// With three processes streaming into one log, a line without a source is a line the reader
/// cannot attribute to anything.
@Suite("UpgradeLogPrefix")
struct UpgradeLogPrefixTests {

    @Test func aLineCarriesItsSource() {
        #expect(UpgradeLogPrefix.line("==> Downloading…", from: "figma") == "[figma] ==> Downloading…")
    }

    @Test func everyLineOfABatchCarriesIt() {
        let prefixed = UpgradeLogPrefix.lines(["a", "b"], from: "slack")
        #expect(prefixed == ["[slack] a", "[slack] b"])
    }

    /// An empty source would render as a bare `[] ` — noise that says nothing. The line is
    /// returned untouched instead.
    @Test func anEmptySourceAddsNothing() {
        #expect(UpgradeLogPrefix.line("plain", from: "") == "plain")
        #expect(UpgradeLogPrefix.lines(["plain"], from: "") == ["plain"])
    }
}
