import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Vendor update completion verifies one installation")
struct VendorUpdateCompletionTests {
    @Test func sameMarketingVersionRequiresTheOfferedSparkleBuild() async throws {
        let old = item(requirement: .init(version: "101", field: .buildVersion, scheme: .numericBuild))
        let checker = checker(app: app(build: "100"), result: .upToDate)
        #expect(try await checker.check(old).outcome == .unconfirmed(.targetNotReached))
        #expect(try await self.checker(app: app(build: "101"), result: .upToDate).check(old).outcome == .confirmed)
    }

    @Test func missingOrDifferentInstallationCannotBeConfirmed() async throws {
        let old = item()
        #expect(try await checker(app: nil, result: .upToDate).check(old).outcome == .unconfirmed(.unreadableApplication))
        var other = app(build: "101")
        other.bundleIdentifier = "com.example.other"
        #expect(try await checker(app: other, result: .upToDate).check(old).outcome == .unconfirmed(.identityChanged))
        other = app(build: "101")
        other.path = URL(fileURLWithPath: "/Other/Example.app")
        #expect(try await checker(app: other, result: .upToDate).check(old).outcome == .unconfirmed(.identityChanged))
    }

    @Test func unavailableSourceAndLegacyTargetStayUnconfirmed() async throws {
        #expect(try await checker(app: app(build: "101"), result: .unavailable).check(item()).outcome == .unconfirmed(.sourceUnavailable))
        var old = item()
        old.completionRequirement = nil
        #expect(try await checker(app: app(build: "101"), result: .upToDate).check(old).outcome == .unconfirmed(.unknownTarget))
    }

    @Test func newerAvailableReleaseRemainsActionable() async throws {
        var newer = item()
        newer.availableVersion = "1.0 (102)"
        newer.completionRequirement = .init(version: "102", field: .buildVersion, scheme: .numericBuild)
        let result = try await checker(app: app(build: "101"), result: .outdated(newer)).check(item())
        #expect(result.outcome == .stillOutdated(newer))
    }

    @Test func sharedPackageIsNotProofThatThisCopyWasUpdated() async throws {
        let old = item(requirement: .init(version: "2.0", field: .sharedPackage, scheme: .buildNumbered))
        #expect(try await checker(app: app(build: "200"), result: .upToDate).check(old).outcome == .unconfirmed(.sharedPackage))
    }

    @Test func versionsChangedDuringNetworkRequestNeedAnotherCheck() async throws {
        let reads = ChangingApplication(first: app(build: "101"), second: app(build: "102"))
        let checker = VendorUpdateCompletionChecker(readApplication: { _ in reads.read() }, checkSource: { _, _ in .upToDate })
        #expect(try await checker.check(item()).outcome == .unconfirmed(.changedDuringCheck))
    }

    @Test func sparkleRetainsMachineReadableTargetAlongsideDisplayLabel() async throws {
        let feed = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <enclosure sparkle:version="101" sparkle:shortVersionString="1.0"/>
        </item></channel></rss>
        """
        let source = SparkleUpdateChecker(client: FakeHTTP.client(ok: feed),
                                         feedOverrides: ["com.example.app": "https://example.invalid/feed"])
        guard case .outdated(let update) = await source.check(app: app(build: "100")) else {
            Issue.record("Expected a newer build"); return
        }
        #expect(update.availableVersion == "1.0 (101)")
        #expect(update.completionRequirement == .init(version: "101", field: .buildVersion, scheme: .numericBuild))
        let restored = try JSONDecoder().decode(ManualOutdatedApp.self, from: JSONEncoder().encode(update))
        #expect(restored.completionRequirement == update.completionRequirement)
    }

    @Test func uncachedReaderSeesReplacementAtTheSamePath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = directory.appendingPathComponent("Example.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = contents.deletingLastPathComponent()
        let plistURL = contents.appendingPathComponent("Info.plist")
        func write(build: Int) throws {
            let plist: [String: Any] = [
                "CFBundleIdentifier": "com.example.app", "CFBundleShortVersionString": "1.0", "CFBundleVersion": build
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        }
        try write(build: 100)
        #expect(VendorUpdateCompletionChecker.application(at: path)?.buildVersion == "100")
        try write(build: 101)
        #expect(VendorUpdateCompletionChecker.application(at: path)?.buildVersion == "101")
    }

    @Test func onlyOneCopyAndOneSelectedSourceAreRead() async throws {
        let old = item()
        let installed = app(build: "101")
        let checker = VendorUpdateCompletionChecker(readApplication: { path in
            #expect(path == old.path)
            return installed
        }, checkSource: { app, source in
            #expect(app.path == old.path)
            #expect(source == .sparkle)
            return .upToDate
        })
        #expect(try await checker.check(old).outcome == .confirmed)
    }

    @Test func legacySnapshotsDecodeWithoutTargetsOrHandoffs() throws {
        let snapshot = ScanSnapshot(scannedAt: Date(), brew: nil, mas: [], npm: [], manual: [item()])
        let data = try JSONEncoder().encode(snapshot)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "vendorHandoffs")
        var rows = try #require(json["manual"] as? [[String: Any]])
        rows[0].removeValue(forKey: "completionRequirement")
        json["manual"] = rows
        let restored = try JSONDecoder().decode(ScanSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.vendorHandoffs.isEmpty)
        #expect(restored.manual.first?.completionRequirement == nil)
    }

    @Test func githubPrereleaseAndMissingBuildDoNotReachStableTarget() {
        var installed = app(build: "101")
        installed.version = "2.0.0-beta.1"
        #expect(!VendorUpdateRequirement(version: "2.0.0", scheme: .semver).isReached(in: installed))
        installed.buildVersion = nil
        #expect(!VendorUpdateRequirement(version: "101", field: .buildVersion, scheme: .numericBuild).isReached(in: installed))
    }

    private func checker(app: ApplicationInfo?, result: ManualCheckResult) -> VendorUpdateCompletionChecker {
        VendorUpdateCompletionChecker(readApplication: { _ in app }, checkSource: { _, _ in result })
    }

    private func item(requirement: VendorUpdateRequirement = .init(version: "101", field: .buildVersion, scheme: .numericBuild)) -> ManualOutdatedApp {
        ManualOutdatedApp(name: "Example", path: app(build: "100").path, installedVersion: "1.0 (100)",
                          availableVersion: "1.0 (101)", source: .sparkle, bundleIdentifier: "com.example.app",
                          completionRequirement: requirement)
    }

    private func app(build: String) -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                        bundleIdentifier: "com.example.app", version: "1.0", buildVersion: build,
                        installDate: nil, updateDate: nil, isManagedByBrew: false)
    }
}

private final class ChangingApplication: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    let first: ApplicationInfo
    let second: ApplicationInfo

    init(first: ApplicationInfo, second: ApplicationInfo) { self.first = first; self.second = second }

    func read() -> ApplicationInfo {
        lock.withLock {
            reads += 1
            return reads == 1 ? first : second
        }
    }
}
