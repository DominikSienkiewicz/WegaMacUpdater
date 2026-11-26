import Foundation
import XCTest
@testable import MacUpdaterCore

@MainActor
final class OldInstallerScannerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let days30: TimeInterval = 30 * 24 * 60 * 60

    @discardableResult
    private func file(_ name: String, in home: CleanupTempHome, age: TimeInterval = 31 * 86400) throws -> URL {
        let url = try home.file(name, size: 12)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func testScanOnlyReturnsOldRegularInstallersDirectlyInsideChosenFolder() async throws {
        let home = try CleanupTempHome()
        let folder = try home.directory("chosen")
        try file("chosen/older.DMG", in: home)
        try file("chosen/exact.pkg", in: home, age: days30)
        try file("chosen/new.pkg", in: home, age: days30 - 1)
        try file("chosen/report.pdf", in: home)
        try file("chosen/deep/hidden.dmg", in: home)
        try file("elsewhere/outside.pkg", in: home)
        try home.directory("chosen/folder.pkg")
        try home.symlink("chosen/link.dmg", to: home.url("elsewhere/outside.pkg").path)
        let scanner = OldInstallerScanner(now: { [now] in now }, trash: { _ in XCTFail("Scan must be read-only") })
        let old = try await scanner.scan(directory: folder)
        XCTAssertEqual(Set(old.installers.map(\.name)), ["older.DMG", "exact.pkg"])
        let all = try await scanner.scan(directory: folder, age: .all)
        XCTAssertEqual(Set(all.installers.map(\.name)), ["older.DMG", "exact.pkg", "new.pkg"])
        XCTAssertTrue(all.installers.allSatisfy { $0.size == 12 && $0.installedVersion == nil })
    }
}

extension OldInstallerScannerTests {
    func testConfirmedFileIsTrashedOnceAndCannotBeRetriedAfterMoving() async throws {
        let home = try CleanupTempHome()
        let original = try file("chosen/archived.pkg", in: home)
        let trash = try home.directory("synthetic-trash")
        let scanner = OldInstallerScanner(now: { [now] in now }, trash: { url in
            try FileManager.default.moveItem(at: url, to: trash.appending(component: "result.pkg"))
        })
        let snapshot = try await scanner.scan(directory: original.deletingLastPathComponent())
        let item = try XCTUnwrap(snapshot.installers.first)
        try await scanner.trash(item, from: snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appending(component: "result.pkg").path))
        do {
            try await scanner.trash(item, from: snapshot)
            XCTFail("A disappeared item must fail revalidation")
        } catch OldInstallerError.itemChanged {}
    }

    func testTrashRechecksIdentitySizeModificationAndAge() async throws {
        let home = try CleanupTempHome()
        let folder = try home.directory("chosen")
        let scanner = OldInstallerScanner(now: { [now] in now }, trash: { _ in XCTFail("Changed file must stay") })
        for name in ["replaced", "size", "mtime", "clock", "link"] {
            try file("chosen/\(name).pkg", in: home)
        }
        let snapshot = try await scanner.scan(directory: folder)
        for item in snapshot.installers {
            let file = folder.appending(component: item.name)
            switch item.name {
            case "replaced.pkg":
                try FileManager.default.moveItem(at: file, to: home.url("old"))
                try self.file("chosen/replaced.pkg", in: home)
            case "size.pkg":
                try Data([1]).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: item.modifiedAt], ofItemAtPath: file.path)
            case "mtime.pkg":
                try FileManager.default.setAttributes([.modificationDate: item.modifiedAt.addingTimeInterval(1)], ofItemAtPath: file.path)
            case "link.pkg":
                try FileManager.default.moveItem(at: file, to: home.url("target"))
                try home.symlink("chosen/link.pkg", to: home.url("target").path)
            default: break
            }
            let validator = item.name == "clock.pkg"
                ? OldInstallerScanner(now: { item.modifiedAt }, trash: { _ in XCTFail("Age must be rechecked") })
                : scanner
            do {
                try await validator.trash(item, from: snapshot)
                XCTFail("Must refuse a changed item: \(item.name)")
            } catch OldInstallerError.itemChanged {}
        }
        XCTAssertEqual(snapshot.installers.count, 5)
    }

    func testFolderReplacementSymlinksAndForeignSnapshotAreRefused() async throws {
        let home = try CleanupTempHome()
        let folder = try home.directory("chosen")
        try file("chosen/File.dmg", in: home)
        let scanner = OldInstallerScanner(now: { [now] in now }, trash: { _ in XCTFail("Foreign folder must stay") })
        let snapshot = try await scanner.scan(directory: folder)
        let item = try XCTUnwrap(snapshot.installers.first)
        let elsewhere = try home.directory("elsewhere")
        let otherScan = try await scanner.scan(directory: elsewhere)
        do {
            try await scanner.trash(item, from: otherScan)
            XCTFail("The review must contain the chosen item")
        } catch OldInstallerError.itemChanged {}
        let movedFolder = home.url("renamed")
        try FileManager.default.moveItem(at: folder, to: movedFolder)
        try home.directory("chosen")
        try FileManager.default.moveItem(at: movedFolder.appending(component: "File.dmg"), to: folder.appending(component: "File.dmg"))
        do {
            try await scanner.trash(item, from: snapshot)
            XCTFail("The folder identity changed")
        } catch OldInstallerError.folderUnavailable {}
        try home.symlink("folder-link", to: folder.path)
        do {
            _ = try await scanner.scan(directory: home.url("folder-link"))
            XCTFail("A symlink must never supply candidates")
        } catch OldInstallerError.folderUnavailable {}
    }
}
