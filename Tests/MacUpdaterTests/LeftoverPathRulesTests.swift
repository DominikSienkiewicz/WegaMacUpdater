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

    /// Another app's container is never read: only the container folder itself may be offered.
    @Test func offerableRefusesAnythingInsideAContainer() {
        #expect(!LeftoverPathRules.isOfferable([
            "Library", "Group Containers", "UBF8T346G9.ms", "Microsoft Word.MERP.params.txt",
        ]))
        #expect(!LeftoverPathRules.isOfferable(["Library", "Containers", "org.sparkle-project.Downloader", "Data", "x"]))
        #expect(!LeftoverPathRules.isOfferable(["library", "GROUP CONTAINERS", "UBF8T346G9.ms", "x"]))
        #expect(LeftoverPathRules.isOfferable(["Library", "Group Containers", "ABCDE12345.com.acme.app"]))
        #expect(LeftoverPathRules.isOfferable(["Library", "Containers", "com.acme.app"]))
        #expect(LeftoverPathRules.isOfferable(["Library", "Containers Backup", "com.acme.app", "Data"]))
    }

    @Test(arguments: ["CloudDocs", "FileProvider", "MobileSync"])
    func offerableRefusesSystemServiceStores(_ folder: String) {
        #expect(!LeftoverPathRules.isOfferable(["Library", "Application Support", folder]))
        #expect(!LeftoverPathRules.isOfferable(["Library", "Application Support", folder, "x"]))
        #expect(!LeftoverPathRules.isOfferable(["library", "APPLICATION SUPPORT", folder.lowercased()]))
        #expect(LeftoverPathRules.isOfferable(["Library", "Application Support", folder + " Backup"]))
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

    @Test func zapComponentsRejectsHiddenSeparators() {
        let entries = [
            "~/a\u{0600}/../Documents", "~/.config/x\u{0600}/..", "~/Documents/\u{301}x/y",
            "~/Library/Mail/\u{301}x/y", "~/../\u{301}Y/z",
        ]
        for entry in entries {
            let components = LeftoverPathRules.zapComponents(entry)
            #expect(components == nil || !LeftoverPathRules.isOfferable(components ?? []), "\(entry)")
        }
        #expect(LeftoverPathRules.zapComponents("~/a\u{0600}/../Documents") == nil)
        #expect(LeftoverPathRules.zapComponents("~/Documents/\u{301}x/y") == ["Documents", "\u{301}x", "y"])
    }

    @Test func offerableRefusesMalformedComponents() {
        #expect(!LeftoverPathRules.isOfferable([".config", ".."]))
        #expect(!LeftoverPathRules.isOfferable(["Library", "Caches", "."]))
        #expect(!LeftoverPathRules.isOfferable(["Library", "Application Support", "a/b"]))
        #expect(!LeftoverPathRules.isOfferable(["", "x"]))
        #expect(!LeftoverPathRules.isOfferable(["x", "a\u{0}b"]))
    }

    @Test func zapComponentsRejectsPureWildcards() {
        #expect(LeftoverPathRules.zapComponents("~/Library/Caches/*") == nil)
        #expect(LeftoverPathRules.zapComponents("~/.config/*.*") == nil)
        #expect(LeftoverPathRules.zapComponents("~/Library/Caches/?") == nil)
        #expect(LeftoverPathRules.zapComponents("~/Library/Group Containers/*.slack") != nil)
        #expect(!LeftoverPathRules.isOfferable(["Library", "Caches", "*"]))
    }

    @Test func offerableRefusesAppleAnywhereInAComponent() {
        #expect(!LeftoverPathRules.isOfferable(["Library", "Group Containers", "group.com.apple.notes"]))
        let recents = ["Library", "Application Support", "com.apple.sharedfilelist",
                       "com.apple.LSSharedFileList.ApplicationRecentDocuments"]
        #expect(LeftoverPathRules.isOfferable(recents + ["md.obsidian.sfl3"]))
        #expect(!LeftoverPathRules.isOfferable(recents + ["com.apple.TextEdit.sfl3"]))
        #expect(!LeftoverPathRules.isOfferable(recents + ["notes.txt"]))
        #expect(!LeftoverPathRules.isOfferable(recents + ["x.sfl3", "deeper.sfl3"]))
    }

    @Test func keyFoldsLikeEquals() {
        #expect(LeftoverPathRules.key(["Straße"]) == LeftoverPathRules.key(["STRASSE"]))
        #expect(LeftoverPathRules.key(["Caf\u{E9}"]) == LeftoverPathRules.key(["Cafe\u{301}"]))
        #expect(LeftoverPathRules.key(["Library"]) == LeftoverPathRules.key(["library"]))
        #expect(LeftoverPathRules.key(["a", "B"]) == "a/b")
    }

    @Test func selectedByDefaultNeedsNoReasonAndNoSharing() {
        let url = URL(filePath: "/tmp/x", directoryHint: .notDirectory)
        let plain = LeftoverItem(url: url, source: .bundleIdentifier)
        let probable = LeftoverItem(url: url, source: .appName, probableReason: .appName)
        let shared = LeftoverItem(url: url, source: .bundleIdentifier, sharedWith: ["Other"])
        #expect([plain, probable, shared].map(\.isSelectedByDefault) == [true, false, false])
    }
}
