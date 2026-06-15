import Testing
import Foundation
@testable import MacUpdaterCore

@Suite("P3Backends")
struct P3BackendsTests {

    // MARK: DEBT-03 — pam module path robustness

    @Test func pamModuleCandidatesCoverVersionedAndPlain() {
        #expect(SystemPaths.pamModuleCandidates.contains("/usr/lib/pam/pam_tid.so.2"))
        #expect(SystemPaths.pamModuleCandidates.contains("/usr/lib/pam/pam_tid.so"))
    }

    // MARK: DEBT-04 — concurrency-safe shared state (API preserved)

    @Test func homebrewEnvironmentStateRoundTrips() {
        let previous = HomebrewEnvironment.askpassPath
        defer { HomebrewEnvironment.askpassPath = previous }
        HomebrewEnvironment.askpassPath = "/tmp/wega-test-askpass.sh"
        #expect(HomebrewEnvironment.askpassPath == "/tmp/wega-test-askpass.sh")
    }

    // MARK: DEBT-05 — installed versions from JSON (robust)

    @Test func parsesInstalledCaskVersionsFromJSON() throws {
        let json = """
        {"formulae":[{"name":"jq","installed":[{"version":"1.7"}]}],
         "casks":[
           {"token":"zoom","installed":"6.0.1"},
           {"token":"never-installed","installed":null}
         ]}
        """
        let map = try BrewInfoParser().parseInstalledVersions(json)
        #expect(map["zoom"] == "6.0.1")
        #expect(map["never-installed"] == nil)   // null installed → pominięty
        #expect(map.count == 1)                  // formulae ignorowane
    }

    // MARK: SEC-09 — Sparkle ignoruje feedy nie-HTTPS

    @Test func sparkleSkipsNonHTTPSFeedWithoutRequesting() async {
        // 500 transport: gdyby guard nie zadziałał, dostalibyśmy .unavailable.
        let checker = SparkleUpdateChecker(
            client: FakeHTTP.client(status: 500),
            feedOverrides: ["com.test.insecure": "http://insecure.example/appcast.xml"]
        )
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Insecure.app"),
            name: "Insecure", bundleIdentifier: "com.test.insecure", version: "1.0",
            installDate: nil, updateDate: nil, isManagedByBrew: false
        )
        #expect(await checker.check(app: app) == .notApplicable)
    }
}
