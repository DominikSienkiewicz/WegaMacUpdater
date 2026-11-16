import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("LeftoverPlanner app-name source")
struct LeftoverPlannerNameTests {
    private let fixture: LeftoverTestHome

    init() throws {
        fixture = try LeftoverTestHome()
    }

    private func plannedItems(_ target: LeftoverApp) -> [LeftoverItem] {
        LeftoverPlanner.plan(
            targets: [target], alsoRemoved: [], others: [], home: fixture.home, fileSystem: LiveCleanupFileSystem()
        ).flatMap(\.items)
    }

    private func app(
        name: String, fileName: String? = nil, bundleID: String? = nil, cask: LeftoverCaskEvidence? = nil
    ) -> LeftoverApp {
        LeftoverApp(
            id: "target", name: name, fileName: fileName ?? name, path: "/Applications/\(name).app",
            bundleIdentifier: bundleID, teamIdentifier: nil, cask: cask
        )
    }

    @Test func nameFoldersAreProbableWithDiskSpelling() throws {
        let support = try fixture.folder("Library/Application Support/zed")
        let logs = try fixture.folder("Library/Logs/Zed")

        let items = plannedItems(app(name: "Zed"))

        #expect(items.map(\.url) == [support, logs])
        #expect(items.map(\.url.lastPathComponent) == ["zed", "Zed"])
        #expect(items.allSatisfy { $0.source == .appName && $0.probableReason == .appName })
        #expect(items.allSatisfy { !$0.isSelectedByDefault })
    }

    @Test func fileNameIsAnotherSourceOfNames() throws {
        let support = try fixture.folder("Library/Application Support/Visual Studio Code")

        #expect(plannedItems(app(name: "Code", fileName: "Visual Studio Code")).map(\.url) == [support])
    }

    @Test func genericAndShortNamesAreSkipped() throws {
        for folder in ["Data", "Go", "Google"] {
            try fixture.folder("Library/Application Support/\(folder)")
            try fixture.folder("Library/Caches/\(folder)")
        }

        for name in ["Data", "Go", "Google"] {
            #expect(plannedItems(app(name: name)).isEmpty)
        }
    }

    @Test func appWithoutBundleIDStillGetsNameItems() throws {
        let caches = try fixture.folder("Library/Caches/Acme")

        #expect(plannedItems(app(name: "Acme", bundleID: nil)).map(\.url) == [caches])
    }

    @Test func nameMatchingIsComponentSafeAndUnicodeEquivalent() throws {
        try fixture.folder("Library/Application Support/AC:DC")
        #expect(plannedItems(app(name: "AC/DC")).isEmpty)

        let nfd = "Cafe\u{301}"
        try fixture.folder("Library/Application Support/\(nfd)")
        let items = plannedItems(app(name: "Caf\u{E9}"))

        #expect(items.count == 1)
        #expect(items.first.map { Array($0.url.lastPathComponent.unicodeScalars) } == Array(nfd.unicodeScalars))
    }

    @Test func unreadableParentSkipsOnlyThatSource() throws {
        let support = try fixture.folder("Library/Application Support/com.acme.app")
        let named = try fixture.folder("Library/Application Support/Acme")
        let caches = try fixture.folder("Library/Caches")
        try fixture.folder("Library/Caches/Acme")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: caches.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: caches.path) }

        let items = plannedItems(app(name: "Acme", bundleID: "com.acme.app"))

        #expect(items.map(\.url) == [support, named])
    }

    @Test func bundleIDBeatsNameForTheSamePath() throws {
        let support = try fixture.folder("Library/Application Support/obsidian")

        let items = plannedItems(app(name: "Obsidian", bundleID: "obsidian"))

        #expect(items.map(\.url) == [support])
        #expect(items.first?.source == .bundleIdentifier)
        #expect(items.first?.isSelectedByDefault == true)
    }

    @Test func anyNonProbableSourceMakesTheItemNonProbable() throws {
        try fixture.folder("Library/Application Support/Acme")
        try fixture.folder("Library/Caches/com.acme.app")
        try fixture.folder("Library/Logs/Acme")
        let weak = LeftoverCaskEvidence(
            token: "acme", zapTrashPaths: ["~/Library/Logs/Acme"], provenance: .token
        )

        let items = plannedItems(app(name: "Acme", bundleID: "com.acme.app", cask: weak))

        let logs = items.first { $0.url.lastPathComponent == "Acme" && $0.url.path.contains("/Logs/") }
        #expect(logs?.source == .homebrewZap(token: "acme"))
        #expect(logs?.probableReason == .caskMatchedByName)
    }

    @Test func bundleIDAndNameFindingTheSamePathIsNotProbable() throws {
        let support = try fixture.folder("Library/Application Support/Acme")
        let items = plannedItems(app(name: "Acme", bundleID: "Acme"))

        #expect(items.map(\.url) == [support])
        #expect(items.first?.probableReason == nil)
    }
}
