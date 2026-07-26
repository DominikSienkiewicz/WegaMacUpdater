import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Running cask detector")
struct RunningCaskDetectorTests {
    /// REL-15 regression: a cask that is **not** one of the 16 hardcoded restart-map tokens
    /// is still detected as running, because detection matches by bundle URL across the whole
    /// installed catalog rather than by a hardcoded process name.
    @Test func detectsRunningCaskOutsideTheRestartMap() {
        let bundle = URL(fileURLWithPath: "/Applications/Acme.app")

        let candidates = RunningCaskDetector.runningApps(
            tokens: ["acme"],
            appPaths: ["acme": bundle],
            running: [target(url: bundle, appName: "Acme", processName: "Acme")],
            overrides: MacUpdaterConstants.restartMap
        )

        #expect(candidates == [RestartInfo(processName: "Acme", appName: "Acme")])
    }

    /// For a mapped token the map's relaunch identity wins over the one derived from the
    /// running app — this is the map's only remaining job: naming an atypical process.
    @Test func mappedTokenOverridesTheDerivedRelaunchIdentity() {
        let bundle = URL(fileURLWithPath: "/Applications/zoom.us.app")

        let candidates = RunningCaskDetector.runningApps(
            tokens: ["zoom"],
            appPaths: ["zoom": bundle],
            running: [target(url: bundle, appName: "Zoom", processName: "Zoom")],
            overrides: ["zoom": RestartInfo(processName: "zoom.us", appName: "zoom.us")]
        )

        #expect(candidates == [RestartInfo(processName: "zoom.us", appName: "zoom.us")])
    }

    /// A cask whose app is not among the running applications is not offered for restart,
    /// even when it is one of the override-map tokens.
    @Test func caskWhoseAppIsNotRunningIsNotDetected() {
        let candidates = RunningCaskDetector.runningApps(
            tokens: ["zoom", "acme"],
            appPaths: [
                "zoom": URL(fileURLWithPath: "/Applications/zoom.us.app"),
                "acme": URL(fileURLWithPath: "/Applications/Acme.app")
            ],
            running: [target(
                url: URL(fileURLWithPath: "/Applications/Something-Else.app"),
                appName: "Something Else",
                processName: "SomethingElse"
            )],
            overrides: MacUpdaterConstants.restartMap
        )

        #expect(candidates.isEmpty)
    }

    /// Candidates come back in the order the tokens were given, skipping the ones not running.
    @Test func candidatesFollowTokenOrderAndSkipTheAbsentOnes() {
        let running = URL(fileURLWithPath: "/Applications/Running.app")
        let stopped = URL(fileURLWithPath: "/Applications/Stopped.app")
        let alsoRunning = URL(fileURLWithPath: "/Applications/Also.app")

        let candidates = RunningCaskDetector.runningApps(
            tokens: ["running", "stopped", "also"],
            appPaths: ["running": running, "stopped": stopped, "also": alsoRunning],
            running: [
                target(url: alsoRunning, appName: "Also", processName: "Also"),
                target(url: running, appName: "Running", processName: "Running")
            ]
        )

        #expect(candidates == [
            RestartInfo(processName: "Running", appName: "Running"),
            RestartInfo(processName: "Also", appName: "Also")
        ])
    }

    private func target(url: URL, appName: String, processName: String) -> RunningApplicationTarget {
        RunningApplicationTarget(
            processIdentifier: 1,
            bundleURL: url,
            bundleIdentifier: nil,
            appName: appName,
            processName: processName
        )
    }
}
