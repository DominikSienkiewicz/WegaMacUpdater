import Foundation
import MacUpdaterCore

// MARK: - What an update would do
//
// ARCH-08 — the dry-run: the exact commands, the casks they name, and the download sizes behind
// them. Read-only by construction, and deliberately apart from the code that executes them —
// the preview's whole value is that it comes from the same planner call the execution makes,
// not from a second description of it.
extension ScanStore {
    func plannedCommands(targetKeys: Set<String>) -> [UpdateCommand] {
        UpdatePlanner.commands(for: UpdatePlanner.plan(selectedKeys: targetKeys))
    }

    /// The casks this run would upgrade, in the order the command lists them.
    func plannedCaskTokens(targetKeys: Set<String>) -> [String] {
        UpdatePlanner.plan(selectedKeys: targetKeys).caskNames
    }

    /// F2 — one HEAD per cask, on demand. `brew info --json` has no size field (verified),
    /// and a CDN may withhold `Content-Length`, so "unknown" is a legitimate answer that the
    /// panel shows verbatim rather than guessing a number.
    func probeDownloadSizes(targetKeys: Set<String>) async {
        guard !probingSizes else { return }
        probingSizes = true
        defer { probingSizes = false }

        let probe = DownloadSizeProbe()
        for token in plannedCaskTokens(targetKeys: targetKeys) where caskSizes[token] == nil {
            guard let url = caskDownloads[token]?.url else { continue }
            caskSizes[token] = await probe.probe(urlString: url)
        }
    }

    /// M3(b) — the cleanup the scan used to perform silently, now behind the user's consent.
}
