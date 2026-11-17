import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Leftover sizing")
struct LeftoverSizingTests {
    private let fileSystem = LiveCleanupFileSystem()

    @discardableResult
    private func write(_ relative: String, in testHome: LeftoverTestHome) throws -> URL {
        let url = testHome.url(relative, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2A, count: 10_000).write(to: url)
        return url
    }

    /// The bytes measured for `item`, or nil (recorded as an issue) when it was not measured.
    private func measuredBytes(_ item: URL, home: URL) -> Int64? {
        let size = LeftoverSizing.measure(item, home: home, fileSystem: fileSystem)
        guard case .bytes(let bytes) = size else {
            Issue.record("expected a measured size, got \(size)")
            return nil
        }
        return bytes
    }

    @Test func measuresFolders() throws {
        let testHome = try LeftoverTestHome()
        try write("Library/Application Support/Vendor/one.db", in: testHome)
        try write("Library/Application Support/Vendor/two.db", in: testHome)
        let folder = testHome.url("Library/Application Support/Vendor", isDirectory: true)

        #expect((measuredBytes(folder, home: testHome.home) ?? 0) >= 20_000)
    }

    @Test(arguments: [
        "Library/Containers/com.vendor.app",
        "Library/Group Containers/group.com.vendor.app",
        "library/CONTAINERS/com.vendor.app",
    ])
    func containersAreNotMeasured(_ relative: String) throws {
        let testHome = try LeftoverTestHome()
        try write("\(relative)/Data/store.db", in: testHome)
        let item = testHome.url(relative, isDirectory: true)

        #expect(LeftoverSizing.measure(item, home: testHome.home, fileSystem: fileSystem) == .unknown)
    }

    @Test func aFolderOnlyNamedLikeContainersIsMeasured() throws {
        let testHome = try LeftoverTestHome()
        try write("Library/Containers Backup/com.vendor.app/store.db", in: testHome)
        let item = testHome.url("Library/Containers Backup/com.vendor.app", isDirectory: true)

        #expect((measuredBytes(item, home: testHome.home) ?? 0) >= 10_000)
    }

    @Test func missingItemIsUnknown() throws {
        let testHome = try LeftoverTestHome()
        let missing = testHome.url("Library/Caches/com.vendor.gone", isDirectory: true)

        #expect(LeftoverSizing.measure(missing, home: testHome.home, fileSystem: fileSystem) == .unknown)
    }
}
