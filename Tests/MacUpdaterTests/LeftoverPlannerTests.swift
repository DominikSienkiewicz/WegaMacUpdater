import Foundation
import Testing
@testable import MacUpdaterCore

/// A throwaway home folder, removed when the test that owns it goes away. It stays at its
/// unresolved temporary path (under the `/var` symlink), so planning from it shows that the
/// parent-chain check stops at the home folder.
final class LeftoverTestHome {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "LeftoverPlannerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ relative: String, isDirectory: Bool) -> URL {
        home.appending(path: relative, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let url = url(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ relative: String) throws -> URL {
        let url = url(relative, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        return url
    }

    /// A folder next to the home folder, outside it.
    @discardableResult
    func outsideFolder(_ name: String) throws -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func symlink(_ relative: String, to destination: URL) throws -> URL {
        let url = url(relative, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination.path)
        return url
    }
}

@Suite("LeftoverPlanner")
struct LeftoverPlannerTests {
    private let fixture: LeftoverTestHome

    init() throws {
        fixture = try LeftoverTestHome()
    }

    private func plan(_ targets: LeftoverApp...) -> [LeftoverPlanGroup] {
        LeftoverPlanner.plan(
            targets: targets, alsoRemoved: [], others: [], home: fixture.home, fileSystem: LiveCleanupFileSystem()
        )
    }

    private func plannedItems(_ target: LeftoverApp) -> [LeftoverItem] {
        plan(target).flatMap(\.items)
    }

    private func app(
        id: String = "target",
        name: String = "Acme",
        bundleID: String?,
        team: String? = nil,
        cask: LeftoverCaskEvidence? = nil
    ) -> LeftoverApp {
        LeftoverApp(
            id: id, name: name, fileName: name, path: "/Applications/\(name).app",
            bundleIdentifier: bundleID, teamIdentifier: team, cask: cask
        )
    }

    private func cask(_ token: String, _ provenance: CaskMatchProvenance, zap: [String]) -> LeftoverCaskEvidence {
        LeftoverCaskEvidence(token: token, zapTrashPaths: zap, provenance: provenance)
    }

    // MARK: - Bundle-id locations

    @Test func findsEveryBundleIDLocationInOrder() throws {
        let layout: [(path: String, isDirectory: Bool)] = [
            ("Library/Application Support/com.acme.app", true),
            ("Library/Preferences/com.acme.app.plist", false),
            ("Library/Caches/com.acme.app", true),
            ("Library/Saved Application State/com.acme.app.savedState", true),
            ("Library/Containers/com.acme.app", true),
            ("Library/HTTPStorages/com.acme.app", true),
            ("Library/HTTPStorages/com.acme.app.binarycookies", false),
            ("Library/WebKit/com.acme.app", true),
            ("Library/Logs/com.acme.app", true),
            ("Library/Application Scripts/com.acme.app", true),
            ("Library/Cookies/com.acme.app.binarycookies", false),
            ("Library/Preferences/ByHost/com.acme.app.0000-1111.plist", false),
            ("Library/Group Containers/ABCDE12345.com.acme.app", true),
            ("Library/Group Containers/group.com.acme.app", true),
            ("Library/Application Support/com.apple.sharedfilelist/"
                + "com.apple.LSSharedFileList.ApplicationRecentDocuments/com.acme.app.sfl3", false),
        ]
        let expected = try layout.map { try $0.isDirectory ? fixture.folder($0.path) : fixture.file($0.path) }

        let groups = plan(app(bundleID: "com.acme.app", team: "ABCDE12345"))

        #expect(groups.map(\.appID) == ["target"])
        let items = groups.flatMap(\.items)
        #expect(items.map(\.url) == expected)
        #expect(items.allSatisfy { $0.source == .bundleIdentifier && $0.isSelectedByDefault })
    }

    @Test func onlyExistingPathsAreOffered() throws {
        let caches = try fixture.folder("Library/Caches/com.acme.app")
        let logs = try fixture.folder("Library/Logs/com.acme.app")
        try fixture.folder("Library/Preferences")
        try fixture.folder("Library/Containers/com.acme.other")

        #expect(plannedItems(app(bundleID: "com.acme.app")).map(\.url) == [caches, logs])
    }

    @Test func unsafeBundleIDOffersNothing() throws {
        try fixture.folder("etc")
        try fixture.file("Library/Preferences/.plist")
        try fixture.folder("Library/Group Containers/group.")

        #expect(plan(app(bundleID: "../../etc")).isEmpty)
        #expect(plan(app(bundleID: "")).isEmpty)
    }

    @Test func teamContainerNeedsAnAlphanumericTeamID() throws {
        try fixture.folder("Library/Group Containers/.com.acme.app")
        try fixture.folder("Library/Group Containers/..com.acme.app")
        let group = try fixture.folder("Library/Group Containers/group.com.acme.app")

        #expect(plannedItems(app(bundleID: "com.acme.app", team: "")).map(\.url) == [group])
        #expect(plannedItems(app(bundleID: "com.acme.app", team: ".")).map(\.url) == [group])
    }

    // MARK: - Homebrew zap list

    @Test func strongZapItemsAreTickedInsideLibrary() throws {
        let support = try fixture.folder("Library/Application Support/obsidian")
        let preferences = try fixture.file("Library/Preferences/md.obsidian.plist")
        let obsidian = app(name: "Obsidian", bundleID: "md.obsidian", cask: cask("obsidian", .token, zap: [
            "~/Library/Application Support/obsidian", "~/Library/Preferences/md.obsidian.plist",
        ]))

        let items = plannedItems(obsidian)

        #expect(items.map(\.url) == [support, preferences])
        #expect(items.map(\.source) == [.homebrewZap(token: "obsidian"), .homebrewZap(token: "obsidian")])
        #expect(items.first?.probableReason == nil)
        #expect(items.allSatisfy { $0.isSelectedByDefault })
    }

    @Test func weakZapItemsAreProbable() throws {
        let support = try fixture.folder("Library/Application Support/obsidian")
        let caches = try fixture.folder("Library/Caches/md.obsidian")
        let obsidian = app(name: "Obsidian", bundleID: "md.obsidian", cask: cask("obsidian", .token, zap: [
            "~/Library/Application Support/obsidian", "~/Library/Caches/md.obsid*",
        ]))

        let items = plannedItems(obsidian)

        #expect(items.map(\.url) == [support, caches])
        #expect(items.first?.source == .homebrewZap(token: "obsidian"))
        #expect(items.first?.probableReason == .caskMatchedByName)
        #expect(items.first?.isSelectedByDefault == false)
        #expect(items.last?.source == .bundleIdentifier)
        #expect(items.last?.probableReason == nil)
    }

    @Test func zapItemsOutsideLibraryAreProbable() throws {
        let config = try fixture.folder(".config/zed")
        let zed = app(name: "Zed", bundleID: "dev.zed.Zed", cask: cask("zed", .bundleIdentifier, zap: ["~/.config/zed"]))

        let items = plannedItems(zed)

        #expect(items.map(\.url) == [config])
        #expect(items.first?.source == .homebrewZap(token: "zed"))
        #expect(items.first?.probableReason == .outsideLibrary)
        #expect(items.first?.isSelectedByDefault == false)
    }

    @Test func wildcardExpansionGatesEachMatch() throws {
        let main = try fixture.folder("Library/Caches/com.vendor.app")
        let helper = try fixture.folder("Library/Caches/com.vendor.app.helper")
        try fixture.folder("Library/Caches/org.other")
        try fixture.file("Library/Preferences/com.apple.finder.plist")
        let vendor = app(name: "Vendor", bundleID: nil, cask: cask("vendor", .curatedMapping, zap: [
            "~/Library/Caches/com.vendor*", "~/Library/Preferences/*", "~/Library/Preferences/*.plist",
        ]))

        let items = plannedItems(vendor)

        #expect(items.map(\.url) == [main, helper])
        #expect(!items.contains { $0.url.lastPathComponent.contains("com.apple.") })
    }

    @Test func symlinkedParentBelowHomeIsRefused() throws {
        try fixture.symlink(".config", to: fixture.outsideFolder("dotfiles"))
        try fixture.outsideFolder("dotfiles/zed")
        let link = try fixture.symlink("Library/Application Support/obsidian", to: fixture.outsideFolder("data"))
        let obsidian = app(name: "Obsidian", bundleID: "md.obsidian", cask: cask("obsidian", .bundleIdentifier, zap: [
            "~/.config/zed", "~/.config/zed*", "~/Library/Application Support/obsidian",
        ]))

        #expect(plannedItems(obsidian).map(\.url) == [link])
    }

    @Test func caseVariantsCollapseToOneItem() throws {
        try fixture.folder("Library/Caches/dev.zed.zed")
        let zed = app(name: "Zed", bundleID: "dev.zed.Zed", cask: cask("zed", .bundleIdentifier, zap: [
            "~/Library/Caches/dev.zed.Zed", "~/Library/Caches/dev.zed.z*",
        ]))

        let items = plannedItems(zed)

        #expect(items.count == 1)
        #expect(items.first?.source == .homebrewZap(token: "zed"))
    }

    @Test func droppedFoldersNeverOffered() throws {
        try fixture.file("Library/LaunchAgents/com.x.plist")
        let agent = app(bundleID: nil, cask: cask("x", .curatedMapping, zap: ["~/Library/LaunchAgents/com.x.plist"]))

        #expect(plan(agent).isEmpty)
    }

    @Test func symlinkedCachesFolderIsRefused() throws {
        try fixture.outsideFolder("caches/com.acme.app")
        try fixture.symlink("Library/Caches", to: fixture.root.appending(path: "caches", directoryHint: .isDirectory))
        let logs = try fixture.folder("Library/Logs/com.acme.app")

        #expect(plannedItems(app(bundleID: "com.acme.app")).map(\.url) == [logs])
    }

    @Test func symlinkDeeperInTheChainIsRefused() throws {
        let dotfiles = try fixture.outsideFolder("dotfiles/zed")
        try Data().write(to: dotfiles.appending(path: "settings.json", directoryHint: .notDirectory))
        try fixture.symlink(".config", to: fixture.root.appending(path: "dotfiles", directoryHint: .isDirectory))
        let zed = app(name: "Zed", bundleID: nil, cask: cask("zed", .bundleIdentifier, zap: ["~/.config/zed/settings.json"]))

        #expect(plan(zed).isEmpty)
    }

    // MARK: - Several targets

    @Test func laterTargetsDoNotRepeatAPlannedPath() throws {
        let acme = try fixture.folder("Library/Caches/com.acme.app")
        let beta = try fixture.folder("Library/Caches/com.beta.app")

        let groups = plan(
            app(id: "first", bundleID: "com.acme.app"),
            app(id: "second", bundleID: "com.acme.app"),
            app(id: "third", bundleID: "com.beta.app")
        )

        #expect(groups.map(\.appID) == ["first", "third"])
        #expect(groups.map { $0.items.map(\.url) } == [[acme], [beta]])
    }
}
