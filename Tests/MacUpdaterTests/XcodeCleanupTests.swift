import Foundation
import Testing
@testable import MacUpdaterCore

struct XcodeCleanupTests {
    @Test func scansProjectCachesSeparatelyFromArchivesWithoutFollowingLinks() async throws {
        let fixture = try XcodeFixture()
        defer { fixture.remove() }
        let project = try fixture.project()
        let sources = fixture.home.appending(path: "src/Design Tools.xcworkspace")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try fixture.directory("DerivedData/ModuleCache.noindex")
        try fixture.directory("DerivedData/Unrelated")
        let outside = try fixture.directory("Other/Outside")
        try fixture.write("Other/Outside/contents", bytes: 512_000)
        try fixture.link("DerivedData/LinkedProject", to: project)
        try fixture.link("DerivedData/Example-hash/External", to: outside)
        let archive = try fixture.directory("Archives/2026-01-01/Distribution.xcarchive")
        let artifacts = try await fixture.engine.scan()
        let cache = try #require(artifacts.first { $0.kind == .derivedData })
        let release = try #require(artifacts.first { $0.kind == .archive })
        #expect(artifacts.count == 2)
        #expect(cache.url.path == project.path)
        #expect(cache.name == "Design Tools")
        #expect(cache.sizeBytes ?? 0 > 0)
        #expect(cache.sizeBytes ?? .max < 512_000)
        #expect(cache.lastModified >= fixture.modifiedFileDate)
        #expect(cache.canTrash)
        #expect(release.url.path == archive.path)
        #expect(!release.canTrash)
        await #expect(throws: (any Error).self) { try await fixture.engine.trash(release) }
        #expect(FileManager.default.fileExists(atPath: archive.path))
        try await fixture.engine.trash(cache)
        #expect(FileManager.default.fileExists(atPath: fixture.trashed.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: sources.path))
    }

    @Test func swiftPackagesUseTheContainingDirectoryName() async throws {
        let fixture = try XcodeFixture()
        defer { fixture.remove() }
        _ = try fixture.project()
        for name in ["Design Tools", "Networking.Core"] {
            let manifest = fixture.home.appending(path: "src").appending(component: name).appending(component: "Package.swift")
            try fixture.writeMetadata(workspace: manifest.path)
            let project = try #require(try await fixture.engine.scan().first)
            #expect(project.name == name)
        }
    }

    @Test func hashedProjectWithBuildOutputsAndNoMetadataIsReadOnly() async throws {
        let fixture = try XcodeFixture()
        defer { fixture.remove() }
        let cacheName = "Older-Project-" + String(repeating: "a", count: 28)
        try fixture.directory("DerivedData/\(cacheName)/Build")
        try fixture.directory("DerivedData/Unrelated/Build")
        let items = try await fixture.engine.scan()
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.name == "Older-Project")
        #expect(!item.canTrash)
        await #expect(throws: (any Error).self) { try await fixture.engine.trash(item) }
    }

    @Test func aDependencyCheckoutWithLocalSourcesMakesTheProjectReadOnly() async throws {
        let fixture = try XcodeFixture()
        defer { fixture.remove() }
        _ = try fixture.project()
        let checkouts = "DerivedData/Example-hash/SourcePackages/checkouts"
        try fixture.directory(checkouts)
        let empty = try #require(try await fixture.engine.scan().first)
        #expect(empty.canTrash)

        try fixture.directory(checkouts + "/Dependency/Sources")
        let source = fixture.xcode.appending(path: checkouts + "/Dependency/Sources/Work.swift")
        let work = Data("let localChanges = true".utf8)
        try work.write(to: source)
        let populated = try #require(try await fixture.engine.scan().first)
        #expect(!populated.canTrash)
        await #expect(throws: (any Error).self) { try await fixture.engine.trash(empty) }
        await #expect(throws: (any Error).self) { try await fixture.engine.trash(populated) }
        #expect(try Data(contentsOf: source) == work)
    }

    @Test func aRunningBuildProtectsThePreviouslyIdleProject() async throws {
        let fixture = try XcodeFixture()
        defer { fixture.remove() }
        let project = try fixture.project()
        let item = try #require(try await fixture.engine.scan().first)
        let compiler = CleanupProcess(pid: 123, name: "swiftc", executablePath: "/usr/bin/swiftc",
                                      arguments: ["-o", project.appending(path: "Build/output").path])
        let busy = XcodeCleanup(home: fixture.home, now: { fixture.now }, processes: { [compiler] },
                                trash: { try FileManager.default.moveItem(at: $0, to: fixture.trashed) })
        await #expect(throws: (any Error).self) { try await busy.trash(item) }
        #expect(FileManager.default.fileExists(atPath: project.path))
    }

    @Test func recentlyWrittenAndChangedDataCannotBeTrashed() async throws {
        let fixture = try XcodeFixture()
        defer { fixture.remove() }
        _ = try fixture.project()
        let cached = try #require(try await fixture.engine.scan().first)
        try FileManager.default.setAttributes([.modificationDate: fixture.now], ofItemAtPath: fixture.buildFile.path)
        let current = try #require(try await fixture.engine.scan().first)
        #expect(!current.canTrash)
        await #expect(throws: (any Error).self) { try await fixture.engine.trash(cached) }
        #expect(!FileManager.default.fileExists(atPath: fixture.trashed.path))
    }

    @Test func refusesReplacedDirectoryAndAncestralSymlink() async throws {
        let fixture = try XcodeFixture()
        defer { fixture.remove() }
        let project = try fixture.project()
        let item = try #require(try await fixture.engine.scan().first)
        try FileManager.default.moveItem(at: project, to: fixture.home.appending(path: "saved"))
        _ = try fixture.project()
        await #expect(throws: (any Error).self) { try await fixture.engine.trash(item) }
        let cachedAgain = try #require(try await fixture.engine.scan().first)
        let derived = project.deletingLastPathComponent()
        let elsewhere = fixture.home.appending(path: "elsewhere")
        try FileManager.default.moveItem(at: derived, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: derived, withDestinationURL: elsewhere)
        await #expect(throws: (any Error).self) { try await fixture.engine.trash(cachedAgain) }
        await #expect(throws: (any Error).self) { _ = try await fixture.engine.scan() }
        #expect(!FileManager.default.fileExists(atPath: fixture.trashed.path))
    }

    @Test func missingXcodeFolderIsEmptyAndContentPointingAtProjectSourcesIsPreserved() async throws {
        let fixture = try XcodeFixture()
        defer { fixture.remove() }
        #expect(try await fixture.engine.scan().isEmpty)
        let project = try fixture.project()
        let nestedWorkspace = project.appending(path: "Sources/App.xcodeproj").path
        try fixture.writeMetadata(workspace: nestedWorkspace)
        let original = try #require(try await fixture.engine.scan().first)
        #expect(!original.canTrash)
        await #expect(throws: (any Error).self) { try await fixture.engine.trash(original) }
        try fixture.writeMetadata(workspace: "/some/other/project.xcodeproj")
        try fixture.directory("DerivedData/Example-hash/OriginalSources")
        let mixed = try #require(try await fixture.engine.scan().first)
        #expect(!mixed.canTrash)
        await #expect(throws: (any Error).self) { try await fixture.engine.trash(mixed) }
        #expect(FileManager.default.fileExists(atPath: project.path))
    }
}

private struct XcodeFixture: Sendable {
    let home: URL
    let now = Date().addingTimeInterval(7200)
    let modifiedFileDate = Date().addingTimeInterval(-1000)

    init() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var xcode: URL { home.appending(path: "Library/Developer/Xcode") }
    var buildFile: URL { xcode.appending(path: "DerivedData/Example-hash/Build/output") }
    var trashed: URL { home.appending(path: "TestTrash") }
    var engine: XcodeCleanup {
        XcodeCleanup(home: home, now: { now }, trash: { try FileManager.default.moveItem(at: $0, to: trashed) })
    }

    func project() throws -> URL {
        _ = try directory("DerivedData/Example-hash/Build")
        try writeMetadata(workspace: home.appending(path: "src/Design Tools.xcworkspace").path)
        try write("DerivedData/Example-hash/Build/output", bytes: 8192)
        try FileManager.default.setAttributes([.modificationDate: modifiedFileDate], ofItemAtPath: buildFile.path)
        return buildFile.deletingLastPathComponent().deletingLastPathComponent()
    }

    func writeMetadata(workspace: String) throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace], format: .binary, options: 0)
        try plist.write(to: xcode.appending(path: "DerivedData/Example-hash/info.plist"))
    }

    @discardableResult
    func directory(_ path: String) throws -> URL {
        let url = xcode.appending(path: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ path: String, bytes: Int) throws {
        try Data(repeating: 19, count: bytes).write(to: xcode.appending(path: path))
    }

    func link(_ path: String, to url: URL) throws {
        try FileManager.default.createSymbolicLink(at: xcode.appending(path: path), withDestinationURL: url)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}
