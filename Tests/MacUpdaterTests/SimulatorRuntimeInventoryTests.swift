import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Installed simulator runtimes")
struct SimulatorRuntimeInventoryTests {
    @Test func readsOnlyTheSelectedToolchainAndSortsVersionsWithinPlatforms() async throws {
        let json = #"""
        {"runtimes":[
          {"identifier":"watch-test","name":"watchOS 10.2","version":"10.2","buildversion":"21S1","isAvailable":false},
          {"identifier":"ios-9","name":"iOS 9.3","version":"9.3","isAvailable":true},
          {"identifier":"ios-18","name":"iOS 18.1","version":"18.1","buildversion":"22B1","isAvailable":true}
        ]}
        """#
        let report = await report(json)
        guard case .loaded(let runtimes) = report.status else {
            Issue.record("Expected three registered runtimes")
            return
        }
        #expect(runtimes.map(\.platform) == ["iOS", "iOS", "watchOS"])
        #expect(runtimes.map(\.version) == ["18.1", "9.3", "10.2"])
        #expect(runtimes.map(\.isAvailable) == [true, true, false])
        #expect(runtimes.first?.buildVersion == "22B1")
        #expect(report.xcodeApplication?.path == "/Fixtures/Xcode Beta.app")
    }

    @Test func distinguishesNoRuntimeFromMissingToolsAndUnreadableInventory() async {
        #expect(await report(#"{"runtimes":[]}"#).status == .loaded([]))
        #expect(await report("{}", hasTool: false).status == .toolUnavailable)
        #expect(await report("", developerDirectory: "").status == .toolUnavailable)
        #expect(await report("{}", exit: 1).status == .failed)
        #expect(await report("{}", exit: 0).status == .failed)
        #expect(await report(#"{"runtimes":[{"identifier":"partial"}]}"#).status == .failed)
    }

    private func report(_ json: String, developerDirectory: String = "/Fixtures/Xcode Beta.app/Contents/Developer",
                        hasTool: Bool = true, exit: Int32 = 0) async -> SimulatorRuntimeReport {
        let read = SimulatorRuntimeInventory(run: { request in
            #expect(request.timeout != nil && request.idleTimeout != nil && request.outputDrainLimit != nil)
            #expect(request.standardInput == .nullDevice && request.outputLogging == .suppressed)
            if request.executableURL.path == "/usr/bin/xcode-select" {
                #expect(request.arguments == ["--print-path"])
                return ProcessResult(exitCode: developerDirectory.isEmpty ? 1 : 0, stdout: developerDirectory, stderr: "")
            }
            #expect(hasTool && !developerDirectory.isEmpty)
            #expect(request.executableURL.path == "/usr/bin/xcrun")
            #expect(request.arguments == ["simctl", "list", "--json", "runtimes"])
            #expect(request.environment["DEVELOPER_DIR"] == developerDirectory)
            return ProcessResult(exitCode: exit, stdout: json, stderr: "")
        }, hasExecutable: { path in
            #expect(path == developerDirectory + "/usr/bin/simctl")
            return hasTool
        })
        return await read.read()
    }
}
