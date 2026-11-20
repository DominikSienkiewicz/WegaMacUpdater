import Foundation
import MacUpdaterCore

/// The spec's `ollama` group as D1 emits it: the Homebrew formula first on `PATH` and the CLI link
/// of Ollama.app, both candidates, resolved for a choice the way the store and the scan resolve it.
enum CleanupKeepFixtures {
    static let formulaPath = "/opt/homebrew/bin/ollama"
    static let linkPath = "/usr/local/bin/ollama"
    static let bundle = URL(filePath: "/Applications/Ollama.app", directoryHint: .isDirectory)
    static let keepLink = ["ollama": CleanupKeptCopy(path: linkPath, source: .appBundle(name: "Ollama"))]
    static let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    static let formula = CleanupFinding(
        detector: .pathDuplicates, tool: "ollama", path: URL(filePath: formulaPath),
        realpath: URL(filePath: "/opt/homebrew/Cellar/ollama/0.40.16/bin/ollama"), source: .homebrewFormula(name: "ollama"),
        version: "0.40.16", size: nil, status: .active, reason: .noCopyKept, action: .none, risk: .low, bucket: .excluded,
        identity: CleanupFileIdentity(device: 1, inode: 61),
        candidate: CleanupCandidate(
            pathRole: .active, removal: .brew(.uninstallFormula("ollama")), removalSize: 70_000_000, dependents: [], processes: []
        )
    )

    static let appLink = CleanupFinding(
        detector: .pathDuplicates, tool: "ollama", path: URL(filePath: linkPath),
        realpath: URL(filePath: "/Applications/Ollama.app/Contents/Resources/ollama"), source: .appBundle(name: "Ollama"),
        version: "0.40.16", size: nil, status: .shadowed, reason: .noCopyKept, action: .none, risk: .low, bucket: .excluded,
        identity: CleanupFileIdentity(device: 1, inode: 62),
        candidate: CleanupCandidate(
            pathRole: .shadowed, removal: .uninstallApp(name: "Ollama", bundle: bundle), removalSize: nil, dependents: [],
            processes: []
        )
    )

    static func path(approximate: Bool) -> CleanupPathSnapshot {
        approximate
            ? CleanupPathSnapshot(entries: ["/usr/local/bin", "/opt/homebrew/bin"], ignoredEntries: [], shell: nil, capturedAt: nil, isApproximate: true)
            : CleanupPathSnapshot(
                entries: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"], ignoredEntries: [], shell: "zsh",
                capturedAt: createdAt, isApproximate: false
            )
    }

    /// The group resolved for `choices`; with none, as the scan delivers it.
    static func report(
        choices: [String: CleanupKeptCopy] = [:], approximate: Bool = false, extra: [CleanupFinding] = []
    ) -> CleanupReport {
        CleanupKeepChoice.apply(choices, to: CleanupReport(
            createdAt: createdAt, path: path(approximate: approximate), findings: [formula, appLink] + extra,
            notes: [], skippedProtected: []
        ))
    }

    static func finding(_ id: String, in report: CleanupReport) -> CleanupFinding? {
        report.findings.first { $0.id == id }
    }
}
