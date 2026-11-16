import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("LeftoverPathRules")
struct LeftoverPathRulesTests {
    private func evidence(
        _ provenance: CaskMatchProvenance, zap: [String]
    ) -> LeftoverCaskEvidence {
        LeftoverCaskEvidence(token: "t", zapTrashPaths: zap, provenance: provenance)
    }

    @Test func zapComponentsAcceptsHomeEntries() {
        #expect(LeftoverPathRules.zapComponents("~/Library/Caches/com.x*") == ["Library", "Caches", "com.x*"])
        #expect(LeftoverPathRules.zapComponents("~/.config/zed/") == [".config", "zed"])
    }

    @Test func zapComponentsRejectsUnsafeEntries() {
        let entries = [
            "/Library/Logs/X", "~/Library/../x", "~/Library//x", "~/Library/*/x",
            "~/Library/**/x", "~/Library/{a,b}", "Library/x",
        ]
        for entry in entries {
            #expect(LeftoverPathRules.zapComponents(entry) == nil, "\(entry)")
        }
    }

    @Test func offerableRespectsDepth() {
        #expect(!LeftoverPathRules.isOfferable([".config"]))
        #expect(!LeftoverPathRules.isOfferable(["Library", "Caches"]))
        #expect(LeftoverPathRules.isOfferable([".config", "zed"]))
        #expect(LeftoverPathRules.isOfferable(["Library", "Caches", "X"]))
    }

    @Test func offerableRefusesProtectedAndDroppedFolders() {
        #expect(!LeftoverPathRules.isOfferable(["Documents", "x"]))
        #expect(!LeftoverPathRules.isOfferable(["library", "mail", "x"]))
        #expect(!LeftoverPathRules.isOfferable(["Library", "LaunchAgents", "com.x.plist"]))
        #expect(!LeftoverPathRules.isOfferable(["Library", "Fonts", "x.ttf"]))
    }

    @Test func offerableRefusesAppleItemsExceptRecentDocuments() {
        #expect(!LeftoverPathRules.isOfferable(["Library", "Preferences", "com.apple.dock.plist"]))
        #expect(!LeftoverPathRules.isOfferable(["Library", "Containers", "com.apple.x", "Data"]))
        #expect(LeftoverPathRules.isOfferable([
            "Library", "Application Support", "com.apple.sharedfilelist",
            "com.apple.LSSharedFileList.ApplicationRecentDocuments", "md.obsidian.sfl3",
        ]))
    }

    @Test func wildcardMatchingFoldsCaseAndSkipsDotfiles() {
        #expect(LeftoverPathRules.matches(
            pattern: "com.tinyspeck.slackmacgap*", name: "com.TinySpeck.SlackMacGap.ShipIt"))
        #expect(!LeftoverPathRules.matches(pattern: "*", name: ".hidden"))
    }

    @Test func strongWhenZapNamesTheBundleID() {
        #expect(evidence(.token, zap: ["~/Library/Preferences/md.obsidian.plist"])
            .isStrong(forBundleIdentifier: "md.obsidian"))
        let zed = "~/Library/Application Support/com.apple.sharedfilelist/"
            + "com.apple.LSSharedFileList.ApplicationRecentDocuments/dev.zed.zed.sfl*"
        #expect(evidence(.token, zap: [zed]).isStrong(forBundleIdentifier: "dev.zed.Zed"))
        #expect(evidence(.token, zap: ["~/Library/Group Containers/*.com.tinyspeck.slackmacgap"])
            .isStrong(forBundleIdentifier: "com.tinyspeck.slackmacgap"))
    }

    @Test func notStrongWhenIDOnlyInsideALongerWord() {
        #expect(!evidence(.token, zap: ["~/Library/Caches/com.acme.appx"])
            .isStrong(forBundleIdentifier: "com.acme.app"))
        #expect(evidence(.curatedMapping, zap: []).isStrong(forBundleIdentifier: "com.acme.app"))
        #expect(!evidence(.displayName, zap: ["~/Library/Caches/other"])
            .isStrong(forBundleIdentifier: "com.acme.app"))
    }

    @Test func selectedByDefaultNeedsNoReasonAndNoSharing() {
        let url = URL(filePath: "/tmp/x", directoryHint: .notDirectory)
        let plain = LeftoverItem(url: url, source: .bundleIdentifier)
        let probable = LeftoverItem(url: url, source: .appName, probableReason: .appName)
        let shared = LeftoverItem(url: url, source: .bundleIdentifier, sharedWith: ["Other"])
        #expect([plain, probable, shared].map(\.isSelectedByDefault) == [true, false, false])
    }
}
