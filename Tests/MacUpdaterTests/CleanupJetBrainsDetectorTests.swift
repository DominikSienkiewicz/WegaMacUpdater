import Foundation
import XCTest
@testable import MacUpdaterCore

final class CleanupJetBrainsDetectorTests: XCTestCase {
    private static let configurations = "Library/Application Support/JetBrains"
    private static let caches = "Library/Caches/JetBrains"
    private static let logs = "Library/Logs/JetBrains"
    private static let toolboxApps = "Library/Application Support/JetBrains/Toolbox/apps"

    private let liveFileSystem = LiveCleanupFileSystem(trash: { _ in })

    private func detector(
        _ home: CleanupTempHome, applicationDirectories: [String] = ["Applications", CleanupJetBrainsDetectorTests.toolboxApps],
        processes: [CleanupProcess] = []
    ) -> CleanupJetBrainsDetector {
        CleanupJetBrainsDetector(
            fileSystem: liveFileSystem, home: home.home,
            inspector: FakeProcessInspector(processes: processes, bootTime: Date(timeIntervalSince1970: 0)),
            applicationDirectories: applicationDirectories.map { home.url($0) }
        )
    }

    /// An IDE bundle; `productInfo` nil leaves `Contents/Resources/product-info.json` out.
    @discardableResult
    private func ide(_ home: CleanupTempHome, _ bundle: String, productInfo: String?) throws -> URL {
        try home.file("\(bundle)/Contents/MacOS/idea", size: 64, executable: true)
        if let productInfo {
            try home.file("\(bundle)/Contents/Resources/product-info.json", text: productInfo)
        }
        return home.url(bundle)
    }

    @discardableResult
    private func ide(_ home: CleanupTempHome, _ bundle: String, dataDirectoryName: String) throws -> URL {
        try ide(home, bundle, productInfo: #"""
        {"name": "JetBrains IDE", "version": "2026.3", "buildNumber": "263.4567.89", "productCode": "IU",
         "dataDirectoryName": "\#(dataDirectoryName)", "launch": [{"os": "macOS", "arch": "aarch64"}]}
        """#)
    }

    @discardableResult
    private func folder(_ home: CleanupTempHome, _ name: String, in location: String = CleanupJetBrainsDetectorTests.configurations) throws -> URL {
        try home.file("\(location)/\(name)/options/ide.general.xml", size: 2048)
        return home.url("\(location)/\(name)")
    }

    private func finding(at url: URL, in findings: [CleanupFinding]) throws -> CleanupFinding {
        try XCTUnwrap(findings.first { $0.path.path == url.path }, "no finding for \(url.lastPathComponent)")
    }

    private func trashedPaths(_ finding: CleanupFinding) -> [String]? {
        guard case .trash(let urls) = finding.action else { return nil }
        return urls.map(\.path)
    }

    /// Brief case 11: IntelliJ IDEA 2026.3 is installed; its older folders and a backup are left over.
    func testOldIdeDirectoriesAreSafeWhenANewerVersionIsInstalled() throws {
        let home = try CleanupTempHome()
        try ide(home, "Applications/IntelliJ IDEA.app", dataDirectoryName: "IntelliJIdea2026.3")
        let leftovers = [
            ("2025.3", try folder(home, "IntelliJIdea2025.3")), ("2026.1", try folder(home, "IntelliJIdea2026.1")),
            ("2026.1", try folder(home, "IntelliJIdea2026.1-backup")), ("2026.2", try folder(home, "IntelliJIdea2026.2")),
        ]
        let current = try folder(home, "IntelliJIdea2026.3")

        let result = detector(home).findings()

        XCTAssertEqual(result.findings.count, 4)
        XCTAssertEqual(result.notes, [])
        for (version, directory) in leftovers {
            let leftover = try finding(at: directory, in: result.findings)
            XCTAssertEqual(leftover.detector, .jetBrains)
            XCTAssertEqual(leftover.tool, "IntelliJIdea")
            XCTAssertEqual(leftover.version, version)
            XCTAssertEqual(leftover.status, .unused)
            XCTAssertEqual(leftover.reason, .ideVersionNotInstalled(installed: ["2026.3"]))
            XCTAssertEqual(trashedPaths(leftover), [directory.path])
            XCTAssertEqual(leftover.risk, .low)
            XCTAssertEqual(leftover.bucket, .safe, directory.lastPathComponent)
            XCTAssertEqual(leftover.realpath?.path, directory.path)
            XCTAssertGreaterThan(leftover.size ?? 0, 0)
            XCTAssertEqual(leftover.identity, try liveFileSystem.entry(at: directory)?.identity)
        }
        XCTAssertNil(result.findings.first { $0.path.path == current.path }, "the installed version's folder was reported")
        XCTAssertEqual(Set(result.findings.map(\.id)).count, result.findings.count, "finding ids must be unique")
        let installed = detector(home).installedDataDirectoryNames()
        XCTAssertEqual(installed.names, ["IntelliJIdea2026.3"])
        XCTAssertEqual(installed.unrecognisedPrefixes, [])
    }

    func testCachesAndLogsAreCandidatesToo() throws {
        let home = try CleanupTempHome()
        try ide(home, "Applications/IntelliJ IDEA.app", dataDirectoryName: "IntelliJIdea2026.3")
        let cache = try folder(home, "IntelliJIdea2026.1", in: Self.caches)
        let log = try folder(home, "IntelliJIdea2026.1", in: Self.logs)
        try folder(home, "IntelliJIdea2026.3", in: Self.caches)
        try folder(home, "IntelliJIdea2026.3", in: Self.logs)

        let found = detector(home).findings().findings

        XCTAssertEqual(found.map(\.path.path).sorted(), [cache.path, log.path].sorted())
        for leftover in found {
            XCTAssertEqual(leftover.status, .unused)
            XCTAssertEqual(leftover.bucket, .safe)
            XCTAssertEqual(trashedPaths(leftover), [leftover.path.path])
        }
    }

    /// Review Focus 5: a product whose IDE Wega cannot find may be installed elsewhere.
    func testProductWithoutInstalledIdeNeedsDecision() throws {
        let home = try CleanupTempHome()
        try ide(home, "Applications/IntelliJ IDEA.app", dataDirectoryName: "IntelliJIdea2026.3")
        let goland = try folder(home, "GoLand2025.2")

        let found = detector(home).findings().findings

        XCTAssertEqual(found.count, 1)
        let orphan = try finding(at: goland, in: found)
        XCTAssertEqual(orphan.tool, "GoLand")
        XCTAssertEqual(orphan.status, .unused)
        XCTAssertEqual(orphan.reason, .ideNotFound)
        XCTAssertEqual(orphan.bucket, .needsDecision)
        XCTAssertEqual(trashedPaths(orphan), [goland.path])

        let bare = try CleanupTempHome()
        let lonely = try folder(bare, "IntelliJIdea2025.3")

        let bareFound = detector(bare).findings().findings

        XCTAssertEqual(try finding(at: lonely, in: bareFound).reason, .ideNotFound)
        XCTAssertEqual(try finding(at: lonely, in: bareFound).bucket, .needsDecision)
    }

    func testNewerThanInstalledNeedsDecision() throws {
        let home = try CleanupTempHome()
        try ide(home, "Applications/IntelliJ IDEA.app", dataDirectoryName: "IntelliJIdea2026.1")
        try ide(home, "Applications/IntelliJ IDEA 2025.app", dataDirectoryName: "IntelliJIdea2025.1")
        let newer = try folder(home, "IntelliJIdea2026.2")
        let between = try folder(home, "IntelliJIdea2025.3")

        let found = detector(home).findings().findings

        let ahead = try finding(at: newer, in: found)
        XCTAssertEqual(ahead.status, .unused)
        XCTAssertEqual(ahead.reason, .newerThanInstalledIDE(installed: ["2025.1", "2026.1"]))
        XCTAssertEqual(ahead.bucket, .needsDecision)
        let left = try finding(at: between, in: found)
        XCTAssertEqual(left.reason, .ideVersionNotInstalled(installed: ["2025.1", "2026.1"]))
        XCTAssertEqual(left.bucket, .safe)
    }

    /// An IDE without a readable product-info.json could be any version of its product.
    func testAppWithoutProductInfoSuspendsItsProduct() throws {
        let home = try CleanupTempHome()
        try ide(home, "Applications/IntelliJ IDEA.app", dataDirectoryName: "IntelliJIdea2026.3")
        try ide(home, "Applications/PyCharm Professional Edition.app", productInfo: nil)
        try ide(home, "Applications/WebStorm.app", productInfo: "{not json")
        try ide(home, "Applications/Safari Technology Preview.app", productInfo: nil)
        try folder(home, "PyCharm2025.1")
        try folder(home, "PyCharmCE2025.1")
        try folder(home, "WebStorm2025.1")
        let idea = try folder(home, "IntelliJIdea2025.3")

        let result = detector(home).findings()

        XCTAssertEqual(result.findings.map(\.path.path), [idea.path])
        XCTAssertEqual(result.findings.first?.bucket, .safe)
        XCTAssertEqual(result.notes, [CleanupDetectorNote(detector: .jetBrains, kind: .unrecognisedIDEInstall)])
        let installed = detector(home).installedDataDirectoryNames()
        XCTAssertEqual(installed.names, ["IntelliJIdea2026.3"])
        XCTAssertEqual(installed.unrecognisedPrefixes, ["PyCharm", "PyCharmCE", "WebStorm"])
    }

    func testUnversionedEntriesAreIgnored() throws {
        let home = try CleanupTempHome()
        try ide(home, "Applications/PyCharm CE.app", dataDirectoryName: "PyCharmCE2024.3")
        for name in ["Toolbox", "consentOptions", "Fleet", "IntelliJIdea2026", "IntelliJIdea2026.1.2", "IntelliJIdea1999.1"] {
            try folder(home, name)
        }
        try home.file("\(Self.configurations)/PyCharm2024.1", size: 16)
        let community = try folder(home, "PyCharmCE2024.1")

        let found = detector(home).findings().findings

        XCTAssertEqual(found.map(\.path.path), [community.path])
        let leftover = try finding(at: community, in: found)
        XCTAssertEqual(leftover.tool, "PyCharmCE")
        XCTAssertEqual(leftover.version, "2024.1")
        XCTAssertEqual(leftover.reason, .ideVersionNotInstalled(installed: ["2024.3"]))
        XCTAssertEqual(leftover.bucket, .safe)

        let parsed = try XCTUnwrap(CleanupJetBrainsNames.parse("PyCharmCE2024.1"))
        XCTAssertEqual(parsed.prefix, "PyCharmCE")
        XCTAssertEqual(parsed.version, "2024.1")
        XCTAssertFalse(parsed.isBackup)
        let backup = try XCTUnwrap(CleanupJetBrainsNames.parse("PyCharm2024.1-backup"))
        XCTAssertEqual(backup.prefix, "PyCharm")
        XCTAssertEqual(backup.version, "2024.1")
        XCTAssertTrue(backup.isBackup)
        for name in ["Toolbox", "consentOptions", "IntelliJIdea2026", "IntelliJIdea1999.1", "IntelliJIdea2026.1-old", "Android2024.1"] {
            XCTAssertNil(CleanupJetBrainsNames.parse(name), name)
        }
        XCTAssertTrue(CleanupJetBrainsNames.productPrefixes.contains("Writerside"))
    }

    /// Toolbox nests an IDE as `apps/<product>/<channel>/<build>/<name>.app`; an application folder
    /// is searched one level deep only.
    func testToolboxAppsAreFoundUpToDepthFour() throws {
        let home = try CleanupTempHome()
        try ide(home, "\(Self.toolboxApps)/IDEA-U/ch-0/263.4567.89/IntelliJ IDEA.app", dataDirectoryName: "IntelliJIdea2026.3")
        try ide(home, "\(Self.toolboxApps)/deep/a/b/c/GoLand.app", dataDirectoryName: "GoLand2026.1")
        try ide(home, "Applications/JetBrains/WebStorm.app", dataDirectoryName: "WebStorm2026.1")

        let installed = detector(home).installedDataDirectoryNames()

        XCTAssertEqual(installed.names, ["IntelliJIdea2026.3"])
        XCTAssertEqual(
            CleanupJetBrainsDetector.defaultApplicationDirectories(home: home.home).map(\.path),
            ["/Applications", home.url("Applications").path, home.url(Self.toolboxApps).path]
        )
    }

    /// IntelliJ IDEA's real product-info.json is over 500 KB, most of it the `layout` array.
    func testLargeProductInfoIsStillRead() throws {
        let home = try CleanupTempHome()
        let layout = (0..<9_000).map { index in
            #"{"name": "plugin\#(index)", "kind": "plugin", "classPath": ["plugins/p\#(index)/lib/p\#(index).jar"]}"#
        }
        let productInfo = """
        {"name": "IntelliJ IDEA", "version": "2026.3", "productCode": "IU", "dataDirectoryName": "IntelliJIdea2026.3",
         "layout": [\(layout.joined(separator: ",\n"))]}
        """
        XCTAssertGreaterThan(productInfo.utf8.count, 600_000, "precondition: larger than the old 256 KB cap")
        try ide(home, "Applications/IntelliJ IDEA.app", productInfo: productInfo)
        let old = try folder(home, "IntelliJIdea2026.1")

        let result = detector(home).findings()

        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(result.findings.map(\.path.path), [old.path])
        XCTAssertEqual(result.findings.first?.reason, .ideVersionNotInstalled(installed: ["2026.3"]))
        XCTAssertEqual(result.findings.first?.bucket, .safe)
        XCTAssertEqual(detector(home).installedDataDirectoryNames().names, ["IntelliJIdea2026.3"])
    }

    /// An application folder that cannot be listed may hold an installed IDE of any version.
    func testUnreadableApplicationFolderKeepsEveryCandidateUndecided() throws {
        try XCTSkipIf(geteuid() == 0, "root can list a 000 directory")
        let home = try CleanupTempHome()
        try ide(home, "Applications/IntelliJ IDEA.app", dataDirectoryName: "IntelliJIdea2026.3")
        let locked = try home.directory("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let old = try folder(home, "IntelliJIdea2025.3")

        let found = detector(home, applicationDirectories: ["Applications", "Locked"]).findings().findings

        let leftover = try finding(at: old, in: found)
        XCTAssertEqual(leftover.reason, .ideVersionNotInstalled(installed: ["2026.3"]))
        XCTAssertEqual(leftover.bucket, .needsDecision)
    }

    func testProcessNamingAFolderMarksItInUse() throws {
        let home = try CleanupTempHome()
        try ide(home, "Applications/IntelliJ IDEA.app", dataDirectoryName: "IntelliJIdea2026.3")
        let cache = try folder(home, "IntelliJIdea2026.1", in: Self.caches)
        let running = CleanupProcess(
            pid: 31, name: "idea", executablePath: "/opt/idea/Contents/MacOS/idea",
            arguments: ["/opt/idea/Contents/MacOS/idea", "-Didea.system.path=\(cache.path)"]
        )

        let found = detector(home, processes: [running]).findings().findings

        let busy = try finding(at: cache, in: found)
        XCTAssertEqual(busy.status, .inUse([running]))
        XCTAssertEqual(busy.bucket, .needsDecision)
    }
}
