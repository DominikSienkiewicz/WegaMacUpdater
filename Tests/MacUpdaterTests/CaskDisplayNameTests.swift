import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Cask display name")
struct CaskDisplayNameTests {
    @Test func theAppsOwnNameWinsAndTheTokenIsTheFallback() {
        #expect(CaskDisplayName.name(token: "visual-studio-code", appPath: URL(fileURLWithPath: "/Applications/Visual Studio Code.app")) == "Visual Studio Code")
        #expect(CaskDisplayName.name(token: "zoom", appPath: URL(fileURLWithPath: "/Applications/zoom.us.app")) == "zoom.us")
        #expect(CaskDisplayName.name(token: "slack", appPath: nil) == "slack")
        #expect(CaskDisplayName.name(token: "x", appPath: URL(fileURLWithPath: "/")) == "x", "never an empty name")
    }
}
