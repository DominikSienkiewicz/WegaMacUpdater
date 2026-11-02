import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Microsoft AutoUpdate handoff")
struct MicrosoftAutoUpdateHandoffTests {
    @Test func officeHasAKnownVendorRouteWithoutACatalogEntry() {
        #expect(CatalogReporting.hasKnownUpdateSource(office(), catalog: AppCatalog()))
    }

    @Test func explicitOfferUsesTheDedicatedVendorAction() {
        let source = ManualOutdatedApp.UpdateSource.microsoftAutoUpdate(applicationID: "MSWD2019")
        #expect(source.updateActionKind == .microsoftAutoUpdate)
        #expect(source.supportsVendorCompletion)
        #expect(source.badgeLabel == "Microsoft AutoUpdate")
    }

    @Test func theVerifiedUpdaterBundleIsOpenedInsteadOfLaunchingOffice() throws {
        let updater = try updaterFixture(identifier: "com.microsoft.autoupdate2")
        defer { try? FileManager.default.removeItem(at: updater) }
        #expect(MicrosoftAutoUpdateHandoff.destination(for: office(), updaterURL: updater) == updater)
    }

    @Test func missingUpdaterLeadsToMicrosoftSupport() {
        #expect(MicrosoftAutoUpdateHandoff.destination(for: office(),
            updaterURL: URL(fileURLWithPath: "/wega-test-fixtures/missing-MAU.app")) == MicrosoftAutoUpdateSupport.supportURL)
    }

    @Test func aForeignBundleIsNeverOpenedAsMAU() throws {
        let updater = try updaterFixture(identifier: "com.example.fake")
        defer { try? FileManager.default.removeItem(at: updater) }
        #expect(MicrosoftAutoUpdateHandoff.destination(for: office(), updaterURL: updater) == MicrosoftAutoUpdateSupport.supportURL)
    }

    @Test func masRoutingIsCheckedAgainAtHandoff() {
        var app = office()
        app.isManagedByMas = true
        #expect(MicrosoftAutoUpdateHandoff.destination(for: app) == nil)
    }

    @Test func noOfferAfterHandoffDoesNotConfirmTheInstallation() async throws {
        var app = office()
        app.version = "16.29.1"
        let installed = app
        let checker = VendorUpdateCompletionChecker(readApplication: { _ in installed }, checkSource: { app, _ in
            MicrosoftAutoUpdateReport(status: .noUpdatesReported).check(app: app)
        })
        let item = ManualOutdatedApp(name: "Word", path: app.path, installedVersion: "16.28", availableVersion: "16.29.1",
            source: .microsoftAutoUpdate(applicationID: "MSWD2019"), bundleIdentifier: app.bundleIdentifier,
            completionRequirement: .init(version: "16.29.1"))
        #expect(try await checker.check(item).outcome == .unconfirmed(.sourceUnavailable))
    }

    private func office() -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/wega-test-fixtures/Word.app"), name: "Word",
            bundleIdentifier: "com.microsoft.Word", version: "16.28", installDate: nil, updateDate: nil, isManagedByBrew: false)
    }

    private func updaterFixture(identifier: String) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
            .write(to: path.appendingPathComponent("Contents/Info.plist"))
        return path
    }
}
