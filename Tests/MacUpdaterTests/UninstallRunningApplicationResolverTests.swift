import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Uninstall running application resolver")
struct UninstallRunningApplicationResolverTests {
    @Test func exactPathMatchIsRunning() {
        let process = target(pid: 11, path: "/Applications/Foo.app", bundleIdentifier: "com.example.foo")

        #expect(
            UninstallRunningApplicationResolver.resolve(
                app: application(path: "/Applications/Foo.app", bundleIdentifier: "com.example.foo"),
                running: [process]
            ) == .running(process)
        )
    }

    @Test func otherCopyWithSameBundleIDIsIgnored() {
        let otherCopy = target(pid: 22, path: "/Users/me/Applications/Foo.app", bundleIdentifier: "com.example.foo")

        #expect(
            UninstallRunningApplicationResolver.resolve(
                app: application(path: "/Applications/Foo.app", bundleIdentifier: "com.example.foo"),
                running: [otherCopy]
            ) == .notRunning
        )
    }

    @Test func sameBundleIDWithoutPathIsAmbiguous() {
        let pathless = target(pid: 33, path: nil, bundleIdentifier: "com.example.foo")

        #expect(
            UninstallRunningApplicationResolver.resolve(
                app: application(path: "/Applications/Foo.app", bundleIdentifier: "com.example.foo"),
                running: [pathless]
            ) == .ambiguousBundleIdentifier("com.example.foo")
        )
    }

    @Test func twoProcessesAtTheSamePathAreAmbiguous() {
        let first = target(pid: 44, path: "/Applications/Foo.app", bundleIdentifier: "com.example.foo")
        let second = target(pid: 45, path: "/Applications/Foo.app", bundleIdentifier: "com.example.foo")

        #expect(
            UninstallRunningApplicationResolver.resolve(
                app: application(path: "/Applications/Foo.app", bundleIdentifier: "com.example.foo"),
                running: [first, second]
            ) == .ambiguousBundleIdentifier("com.example.foo")
        )
    }

    @Test func noBundleIDAndNoPathMatchIsNotRunning() {
        let pathless = target(pid: 55, path: nil, bundleIdentifier: nil)
        let otherCopy = target(pid: 56, path: "/Users/me/Applications/Foo.app", bundleIdentifier: nil)

        #expect(
            UninstallRunningApplicationResolver.resolve(
                app: application(path: "/Applications/Foo.app", bundleIdentifier: nil),
                running: [pathless, otherCopy]
            ) == .notRunning
        )
    }

    private func application(path: String, bundleIdentifier: String?) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: path),
            name: "Foo",
            bundleIdentifier: bundleIdentifier,
            version: nil,
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false,
            caskToken: nil
        )
    }

    private func target(pid: Int32, path: String?, bundleIdentifier: String?) -> RunningApplicationTarget {
        RunningApplicationTarget(
            processIdentifier: pid,
            bundleURL: path.map { URL(fileURLWithPath: $0) },
            bundleIdentifier: bundleIdentifier,
            appName: "Foo",
            processName: "Foo"
        )
    }
}
