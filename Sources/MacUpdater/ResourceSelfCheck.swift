import Foundation
import MacUpdaterCore

/// The process entry point, so a build can be asked whether it can read its own resources
/// without starting the interface.
///
/// v0.2.0 shipped an app that trapped on launch because `Bundle.module` looks for its resource
/// bundle in the `.app` directory and in the build directory of the machine that compiled it —
/// neither of which exists on a user's Mac. Every gate was green: the unit tests run in a layout
/// where the accessor happens to be right, and `verify-bundle.sh` can see that a file is inside
/// the bundle but not that the program can reach it.
///
/// Launching the app and watching it was tried first and rejected: the crashing path runs from a
/// throttled background task, so the released build survived roughly one launch in three. A gate
/// whose verdict depends on timing teaches people to re-run it, which is worse than no gate.
/// Asking the question directly is deterministic.
@main
enum WegaMain {

    /// Undocumented on purpose — this is a build-pipeline probe (`scripts/test-app-launches.sh`),
    /// not a feature. It reads two bundled JSON files and exits; there is nothing here to misuse.
    static let selfCheckFlag = "--wega-selfcheck-resources"

    static func main() {
        if CommandLine.arguments.contains(selfCheckFlag) {
            exit(runResourceSelfCheck())
        }
        WegaMacUpdaterApp.main()
    }

    /// Loads exactly what the app loads, through the same public entry points, so the probe
    /// cannot pass while the real call sites fail. Checking that the files exist would not have
    /// caught v0.2.0 — they existed.
    private static func runResourceSelfCheck() -> Int32 {
        do {
            _ = try AppEndpoints.loadBundled()
            _ = try AppCatalog.loadBundled()
            print("wega: bundled resources are readable (endpoints.json, app-catalog.json)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("""
                wega: bundled resources are UNREADABLE — \(error)
                The packaged app cannot load endpoints.json / app-catalog.json. Compare where
                build-pkg.sh copies the MacUpdaterCore resource bundle with the directories
                ModuleResources searches.

                """.utf8))
            return 1
        }
    }
}
