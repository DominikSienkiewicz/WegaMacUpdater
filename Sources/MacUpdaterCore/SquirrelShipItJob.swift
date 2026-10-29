import Darwin
import Foundation
import WegaHelperKit

/// ShipIt — the installer Squirrel.Mac, the updater built into Electron apps (Discord, Slack,
/// VS Code, …), starts once the app has downloaded an update of its own.
///
/// Squirrel submits ShipIt as a launchd job in the user's GUI domain and ShipIt then waits: it
/// swaps the bundle only after the app it updates has quit. That makes the LT-02 smoke test's
/// teardown the trigger for an install Wega never asked for. Discord's feed lags its cask and
/// answers *any* other version with its current build, so an instance freshly upgraded by
/// Homebrew downloads the older build within the five-second window and ShipIt puts it back the
/// moment the smoke test quits the app (2026-10-27: `0.0.420` → `0.0.419`, twice).
///
/// The job is recognised by what it runs, not by its name: Squirrel derives the label from an
/// identifier of the app's choosing (`com.discord.discord.ShipIt` for the bundle
/// `com.hnc.Discord`), so only the program path ties a job to a bundle.
public enum SquirrelShipItJob {
    private static let labelSuffix = ".ShipIt"
    private static let programKey = "program = "

    /// Labels in `launchctl list` output (`PID\tStatus\tLabel`) that name a ShipIt job.
    public static func candidateLabels(inLaunchctlList output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { return nil }
            let label = columns[2].trimmingCharacters(in: .whitespaces)
            return label.hasSuffix(labelSuffix) ? label : nil
        }
    }

    /// The `program` a job runs, from `launchctl print gui/<uid>/<label>` output.
    public static func programPath(inLaunchctlPrint output: String) -> String? {
        output.split(separator: "\n")
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(programKey) }
            .map { String($0.dropFirst(programKey.count)) }
    }

    /// Whether `path` lives inside `bundle` — compared on whole path components, so a sibling
    /// whose name merely starts with the bundle's does not count.
    public static func program(_ path: String, belongsTo bundle: URL) -> Bool {
        let contents = bundle.standardizedFileURL.path + "/Contents/"
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(contents)
    }

    /// Removes every ShipIt job whose program lives inside `bundle`, and returns their labels.
    ///
    /// Only safe while the app the job updates is still running: ShipIt touches nothing until
    /// that app has quit, so removing it then cancels an install that has not begun. Homebrew's
    /// own `discord` cask removes the same job on uninstall for the same reason. Squirrel
    /// downloads the update again the next time it decides one is due, so nothing of the app's
    /// is lost — only the install this teardown would have triggered.
    @discardableResult
    public static func withdraw(fromBundleAt bundle: URL, runner: ProcessRunning = ProcessRunner()) async -> [String] {
        guard let list = await launchctl(["list"], runner: runner) else { return [] }
        var withdrawn: [String] = []
        for label in candidateLabels(inLaunchctlList: list) {
            guard let printed = await launchctl(["print", "gui/\(getuid())/\(label)"], runner: runner),
                  let program = programPath(inLaunchctlPrint: printed),
                  self.program(program, belongsTo: bundle),
                  await launchctl(["remove", label], runner: runner) != nil else { continue }
            withdrawn.append(label)
        }
        return withdrawn
    }

    private static func launchctl(_ arguments: [String], runner: ProcessRunning) async -> String? {
        let request = ProcessRequest(executableURL: SystemPaths.launchctl, arguments: arguments, timeouts: .quick)
        guard let result = try? await runner.run(request), result.exitCode == 0 else { return nil }
        return result.stdout
    }
}
