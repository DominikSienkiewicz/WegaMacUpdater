import Foundation
@testable import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// 2026-11-22: on a metered Wi-Fi with Low Data Mode the merge gate failed five update-run tests
/// on a branch that changed only scan views. A window run asked `DownloadResourcePreflight`
/// directly, which reads the live network, so every harness store's run was postponed as a
/// metered download and no cask was upgraded. The run now asks the store's
/// `resourceDecision`: the app's is the live preflight, and a test's says it outright.
@Suite("A window run asks the store's resource decision") @MainActor
struct WindowRunResourceDecisionTests {
    private enum StubError: Error {
        case unexpected([String])
    }

    @Test func theRunAsksTheInjectedDecisionAndHoldsWhenItPostpones() async {
        let token = "gate-\(UUID().uuidString)"
        let baseline = Set(UpdateOperationStore.shared.operations().map(\.id))
        defer { removeScanStoreRuntimeOperations(createdAfter: baseline) }
        let asked = AskedTokens()
        let (harness, runner) = Self.harness(token) { tokens, _, _ in
            asked.tokens.append(contentsOf: tokens)
            return .postpone(reason: .lowBattery)
        }

        await harness.store.runUpdate(targetKeys: [UpdatePlanner.key(name: token, kind: .cask)])

        #expect(asked.tokens == [token], "the run asks the store's decision, once, for its cask")
        #expect(!runner.upgraded(token), "a postponed run starts no brew process")
    }

    @Test func aRunTheDecisionAllowsUpgradesWhateverTheNetworkSays() async {
        let token = "gate-\(UUID().uuidString)"
        let baseline = Set(UpdateOperationStore.shared.operations().map(\.id))
        defer { removeScanStoreRuntimeOperations(createdAfter: baseline) }
        let (harness, runner) = Self.harness(token) { _, _, _ in .allow }

        await harness.store.runUpdate(targetKeys: [UpdatePlanner.key(name: token, kind: .cask)])

        #expect(runner.upgraded(token))
    }

    @Test func lowDiskOffersCleanupWithTheShortfallAndKeepsTheQueueForRetry() async throws {
        let token = "space-\(UUID().uuidString)"
        defer {
            for operation in UpdateOperationStore.shared.operations() where operation.items.contains(where: { $0.token == token }) {
                UpdateOperationStore.shared.removeOperation(id: operation.id)
            }
        }
        let key = UpdatePlanner.key(name: token, kind: .cask)
        let asked = AskedTokens()
        let (harness, runner) = Self.harness(token) { _, _, _ in
            asked.tokens.append(token)
            return asked.tokens.count == 1
                ? .postpone(reason: .insufficientDisk(required: 5_000_000_000, available: 2_000_000_000))
                : .allow
        }
        harness.store.selected = [key]

        await harness.store.runUpdate(targetKeys: [key])

        let banner = try #require(harness.store.banner)
        #expect(banner.action == .openCleanup)
        let shortfall = ByteCountFormatter.string(fromByteCount: 3_000_000_000, countStyle: .file)
        #expect(banner.message.contains(shortfall))
        #expect(harness.store.selected == [key])
        #expect(!runner.upgraded(token))

        await harness.store.runUpdate(targetKeys: harness.store.selected)
        #expect(asked.tokens == [token, token])
        #expect(runner.upgraded(token))
        #expect(harness.store.banner?.action != .openCleanup)
    }

    @Test(arguments: [PostponeReason.diskSpaceUnknown, .meteredNetwork, .lowBattery])
    func otherResourceProblemsKeepTheDiagnosticsAction(_ reason: PostponeReason) async {
        let token = "conditions-\(UUID().uuidString)"
        let (harness, _) = Self.harness(token) { _, _, _ in .postpone(reason: reason) }
        await harness.store.runUpdate(targetKeys: [UpdatePlanner.key(name: token, kind: .cask)])
        #expect(harness.store.banner?.action == .openLogs)
    }

    /// The app's store keeps the live gate: network, battery, heat and disk. Only a store that
    /// says otherwise, a test's, skips it.
    @Test func theAppsStoreAsksTheLivePreflight() throws {
        let store = try source("Sources/MacUpdater/ScanStore.swift")
        let declaration = try #require(store.range(of: "var resourceDecision: @MainActor ("))
        #expect(store[declaration.upperBound...].prefix(260).contains(
            "= { await DownloadResourcePreflight.decision(tokens: $0, downloadSizes: $1, appPaths: $2) }"
        ))
        let live = try #require(store.range(of: "static let live = ScanStoreDependencies("))
        #expect(!store[live.upperBound...].contains("resourceDecision:"), "the app's store takes the live default")

        let rollback = try source("Sources/MacUpdater/ScanStore+Rollback.swift")
        let start = try #require(rollback.range(of: "func foregroundResourceDecision("))
        let body = rollback[start.upperBound...].prefix(500)
        #expect(body.contains("return await dependencies.resourceDecision(caskNames, sizes, appPaths)"))
        #expect(!body.contains("DownloadResourcePreflight"))
    }

    private static func harness(
        _ token: String,
        resourceDecision: @escaping @MainActor ([String], [String: DownloadSizeProbeResult], [String: URL]) async -> DownloadGate.Decision
    ) -> (ScanStoreRuntimeHarness, ScanStoreRuntimeProcessRunner) {
        let runner = ScanStoreRuntimeProcessRunner(
            run: { request in
                let arguments = request.arguments
                if arguments.starts(with: ["info", "--cask", "--json=v2"]) {
                    return ProcessResult(exitCode: 0, stdout: #"{"casks":[]}"#, stderr: "")
                }
                switch arguments {
                case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                    return ProcessResult(exitCode: 0, stdout: #"{"formulae":[],"casks":[]}"#, stderr: "")
                case ["outdated"]:
                    return ProcessResult(exitCode: 0, stdout: "", stderr: "")
                case ["outdated", "-g", "--json"]:
                    return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
                default:
                    throw StubError.unexpected(arguments)
                }
            },
            events: { request in
                guard request.arguments.starts(with: ["upgrade", "--cask"]), let token = request.arguments.last else {
                    return .failure(StubError.unexpected(request.arguments))
                }
                return .success([
                    .stdout("Successfully upgraded \(token)\n"),
                    .finished(ProcessResult(exitCode: 0, stdout: "", stderr: "")),
                ])
            }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner, resourceDecision: resourceDecision)
        harness.store.brewOutdated = BrewOutdated(
            formulae: [],
            casks: [BrewOutdatedItem(name: token, installedVersions: ["1"], currentVersion: "2")]
        )
        harness.store.caskDownloads[token] = CaskDownloadInfo(token: token, url: nil, sha256: nil)
        harness.store.caskProfiles[token] = CaskArtifactProfile(token: token, artifacts: [CaskArtifact(kind: .app, names: ["\(token).app"])])
        return (harness, runner)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

@MainActor
private final class AskedTokens {
    var tokens: [String] = []
}

private extension ScanStoreRuntimeProcessRunner {
    func upgraded(_ token: String) -> Bool {
        requests.contains { $0.arguments.starts(with: ["upgrade", "--cask"]) && $0.arguments.last == token }
    }
}
