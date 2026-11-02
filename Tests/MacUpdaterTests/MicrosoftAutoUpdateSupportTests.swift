import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Microsoft Office update routing")
struct MicrosoftAutoUpdateSupportTests {
    @Test(arguments: [
        ("com.microsoft.Word", "MSWD2019"),
        ("com.microsoft.Excel", "XCEL2019"),
        ("com.microsoft.Powerpoint", "PPT32019"),
        ("com.microsoft.Outlook", "OPIM2019"),
        ("com.microsoft.onenote.mac", "ONMC2019"),
    ])
    func vendorOfficeUsesTheDocumentedApplicationIdentifier(bundleID: String, applicationID: String) {
        #expect(MicrosoftAutoUpdateSupport.applicationID(for: app(bundleID: bundleID)) == applicationID)
    }

    @Test func appStoreManagedOfficeStaysOnTheAppStoreRoute() {
        var office = app(bundleID: "com.microsoft.Word")
        office.isManagedByMas = true
        #expect(MicrosoftAutoUpdateSupport.applicationID(for: office) == nil)
    }

    @Test func appStoreIdentityWithoutManagedFlagStillPreventsMAURouting() {
        var office = app(bundleID: "com.microsoft.Word")
        office.masAppID = "462054704"
        #expect(MicrosoftAutoUpdateSupport.applicationID(for: office) == nil)
    }

    @Test func receiptExcludesTheExactCopyEvenWithoutMASMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = directory.appendingPathComponent("Contents/_MASReceipt/receipt")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: receipt)
        var office = app(bundleID: "com.microsoft.Word")
        office.path = directory
        #expect(MicrosoftAutoUpdateSupport.applicationID(for: office) == nil)
        office.path = directory.appendingPathComponent("Second Copy.app")
        #expect(MicrosoftAutoUpdateSupport.applicationID(for: office) == "MSWD2019")
    }

    @Test(arguments: ["com.example.Word", "com.microsoft.teams2", "com.microsoft.edgemac", "com.microsoft.Word.helper"])
    func namesAndMicrosoftPrefixesDoNotIdentifyOffice(bundleID: String) {
        #expect(MicrosoftAutoUpdateSupport.applicationID(for: app(bundleID: bundleID)) == nil)
    }

    @Test func missingVersionDoesNotInventAnUpdateOrHideTheVendorRoute() {
        var office = app(bundleID: "com.microsoft.Word")
        office.version = nil
        office.buildVersion = nil
        #expect(MicrosoftAutoUpdateSupport.applicationID(for: office) == "MSWD2019")
    }

    private func app(bundleID: String) -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/wega-test-fixtures/Office.app"), name: "Microsoft Word",
                        bundleIdentifier: bundleID, version: "16.90", buildVersion: "24101387",
                        installDate: nil, updateDate: nil, isManagedByBrew: false)
    }
}
