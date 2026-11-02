import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Thunderbird compares the installed release channel")
struct ThunderbirdUpdateCheckerTests {
    private let feed = """
    {
      "LATEST_THUNDERBIRD_VERSION": "145.0.1",
      "THUNDERBIRD_ESR": "140.5.0esr",
      "THUNDERBIRD_ESR_NEXT": "153.0esr",
      "LATEST_THUNDERBIRD_DEVEL_VERSION": "146.0b10"
    }
    """

    @Test func esrInstallationNeverUsesTheMonthlyReleaseOrNextESRTrain() async {
        let result = await checker(channel: .esr).check(app: app(version: "140.4.0"))
        guard case .outdated(let item) = result else {
            Issue.record("An older ESR installation must offer the official ESR update"); return
        }
        #expect(item.availableVersion == "140.5.0esr")
        #expect(item.source.badgeLabel == "Thunderbird ESR")
        #expect(item.source.updateActionKind == .launchApp)
        #expect(item.source.supportsVendorCompletion)
        #expect(item.completionRequirement != nil)
    }

    @Test func monthlyReleaseUsesOnlyTheReleaseField() async {
        guard case .outdated(let item) = await checker(channel: .release).check(app: app(version: "144.0")) else {
            Issue.record("Release installation must offer the monthly release"); return
        }
        #expect(item.availableVersion == "145.0.1")
        #expect(item.source.badgeLabel == "Thunderbird Release")
    }

    @Test func newerESRInstallationUsesTheMatchingESRTrain() async {
        let source = checker(channel: .esr, body: feed.replacingOccurrences(of: "153.0esr", with: "153.1.0esr"))
        guard case .outdated(let item) = await source.check(app: app(version: "153.0")) else {
            Issue.record("The newer ESR train must not compare against the older train"); return
        }
        #expect(item.availableVersion == "153.1.0esr")
    }

    @Test func betaVersionsUseNumericPrereleaseOrdering() async {
        guard case .outdated(let item) = await checker(channel: .beta).check(app: app(version: "146.0b9")) else {
            Issue.record("Beta 10 must be offered to Beta 9, independently of Release and ESR"); return
        }
        #expect(item.availableVersion == "146.0b10")
        #expect(item.source.badgeLabel == "Thunderbird Beta")
    }

    @Test func betaCompletionRequiresTheOfferedPrereleaseNumber() async throws {
        guard case .outdated(let item) = await checker(channel: .beta).check(app: app(version: "146.0b9")) else {
            Issue.record("A beta update must retain a machine-readable completion target"); return
        }
        let target = try #require(item.completionRequirement)
        #expect(!target.isReached(in: app(version: "146.0b9")))
        #expect(target.isReached(in: app(version: "146.0b10")))
    }

    @Test func currentESRIsNotOutdatedBecauseMonthlyReleaseIsNewer() async {
        #expect(await checker(channel: .esr).check(app: app(version: "140.5.0")) == .upToDate)
    }

    @Test func missingChannelAndUncomparableBetaAreUnknown() async {
        #expect(await checker(channel: nil).check(app: app(version: "140.4.0")) == .unavailable)
        #expect(await checker(channel: .beta).check(app: app(version: "146.0")) == .unavailable)
    }

    @Test func missingSelectedFieldNeverFallsBackToAnotherChannel() async {
        let body = #"{"LATEST_THUNDERBIRD_VERSION":"145.0.1"}"#
        #expect(await checker(channel: .esr, body: body).check(app: app(version: "140.4.0")) == .failed)
        #expect(await checker(channel: .release, body: "garbage").check(app: app(version: "144.0")) == .failed)
    }

    @Test func networkAndStatusFailuresRemainVisible() async {
        let app = app(version: "144.0")
        let unavailable = ThunderbirdUpdateChecker(client: FakeHTTP.client(status: 503), readChannel: { _ in .release })
        let failed = ThunderbirdUpdateChecker(client: FakeHTTP.client(status: 404), readChannel: { _ in .release })
        #expect(await unavailable.check(app: app) == .unavailable)
        #expect(await failed.check(app: app) == .failed)
    }

    @Test func sameNameWithoutThunderbirdIdentityIsNotApplicable() async {
        var other = app(version: "144.0")
        other.bundleIdentifier = "com.example.thunderbird"
        #expect(await checker(channel: .release).check(app: other) == .notApplicable)
    }

    @Test(arguments: [ThunderbirdReleaseChannel.release, .esr, .beta])
    func applicationINIIdentifiesTheConcreteInstallation(channel: ThunderbirdReleaseChannel) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = directory.appendingPathComponent("Thunderbird.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let remotingName = channel == .release ? "thunderbird" : "thunderbird-\(channel.rawValue)"
        try "[App]\nName=Thunderbird\nRemotingName=\(remotingName)\nVersion=140.0\n"
            .write(to: resources.appendingPathComponent("application.ini"), atomically: true, encoding: .utf8)
        #expect(ThunderbirdInstallationChannel.read(at: resources.deletingLastPathComponent().deletingLastPathComponent()) == channel)
    }

    @Test func missingInstallationMetadataCannotGuessAChannel() {
        #expect(ThunderbirdInstallationChannel.read(at: URL(fileURLWithPath: "/missing/Thunderbird.app")) == nil)
    }

    private func checker(channel: ThunderbirdReleaseChannel?, body: String? = nil) -> ThunderbirdUpdateChecker {
        ThunderbirdUpdateChecker(client: FakeHTTP.client(ok: body ?? feed), readChannel: { _ in channel })
    }

    private func app(version: String) -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Thunderbird.app"), name: "Thunderbird",
                        bundleIdentifier: "org.mozilla.thunderbird", version: version, buildVersion: "1",
                        installDate: nil, updateDate: nil, isManagedByBrew: false)
    }
}
