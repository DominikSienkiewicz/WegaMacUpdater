import Combine
import Foundation
@testable import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// Owner decision 2026-11-21: while the Touch ID card's checks say the settings `sudo` reads cannot
/// be trusted, the window's run starts nothing that may ask for the administrator password, says so
/// on the row and in the summary, and runs everything else. It asks right before the run starts and
/// again before each such item.
@Suite("Update run — no password prompt while sudo cannot be trusted") @MainActor
struct SudoPasswordHoldRunTests {
    private enum StubError: Error {
        case unexpected([String])
    }

    private static let heldNotePL =
        "pominęłam: może potrzebować hasła administratora, a ustawieniom, które czyta sudo, nie można teraz ufać — co zrobić, mówi karta Touch ID w Ustawieniach"

    @Test func aClosedGateHoldsTheCasksThatMayAskAndRunsTheRest() async {
        let plain = "plain-\(UUID().uuidString)"
        let pkg = "pkg-\(UUID().uuidString)"
        let cleanup = RunCleanup()
        defer { cleanup.restore() }
        let (harness, runner) = Self.harness(serial: [pkg], plain: [plain], distrust: { .noProofOfSafety })
        let boards = BoardRecorder(harness.store)

        await harness.store.runUpdate(targetKeys: Self.keys(plain, pkg))

        #expect(runner.upgraded(plain))
        #expect(!runner.upgraded(pkg), "no brew process for a cask that may ask")
        let pkgKey = UpdatePlanner.key(name: pkg, kind: .cask)
        let plainKey = UpdatePlanner.key(name: plain, kind: .cask)
        #expect(boards.seen.contains { $0.rows[pkgKey] == .heldForPassword && $0.rows[plainKey] == .waiting },
                "held from the start, before the rest begins")
        let report = harness.store.runReport
        let held = report?.entries.first { $0.key == pkgKey }
        #expect(held?.wasHeldForPassword == true)
        #expect(held?.result == .notStarted)
        withLanguage(.pl) { #expect(held?.note(undo: nil) == Self.heldNotePL) }
        #expect(report?.entries.first { $0.key == plainKey }?.result == .updated)
        #expect(report?.status == .incomplete)
        #expect(report?.failureLogLinesBeyondTheSummary.contains { $0.hasPrefix("\(pkg): pominięto") } == true)
    }

    @Test func settingsThatTurnUnsafeMidRunHoldTheNextCask() async {
        let first = "pkg-a-\(UUID().uuidString)"
        let second = "pkg-b-\(UUID().uuidString)"
        let cleanup = RunCleanup()
        defer { cleanup.restore() }
        let answers = Answers([nil, nil, .unsafePolicy(.unsafeOwnership)])
        let (harness, runner) = Self.harness(serial: [first, second], plain: [], distrust: { answers.next() })

        await harness.store.runUpdate(targetKeys: Self.keys(first, second))

        #expect(answers.asked == 3, "once at the start, once before each cask that may ask")
        #expect([first, second].filter { runner.upgraded($0) }.count == 1, "the first runs, the second is held")
        let held = harness.store.runReport?.entries.filter(\.wasHeldForPassword) ?? []
        #expect(held.count == 1)
        #expect(held.first.map { !runner.upgraded($0.name) } == true)
    }

    @Test func anOpenGateHoldsNothing() async {
        let pkg = "pkg-\(UUID().uuidString)"
        let cleanup = RunCleanup()
        defer { cleanup.restore() }
        let (harness, runner) = Self.harness(serial: [pkg], plain: [], distrust: { nil })

        await harness.store.runUpdate(targetKeys: Self.keys(pkg))

        #expect(runner.upgraded(pkg))
        #expect(harness.store.runReport?.entries.contains(where: \.wasHeldForPassword) == false)
        #expect(harness.store.runReport?.status == .finished)
    }

    @Test func aClosedGateKeepsMasFromAskingAndSaysWhy() async {
        let runner = ScanStoreRuntimeProcessRunner(
            run: { request in
                switch request.arguments {
                case ["upgrade", "123"]:
                    return ProcessResult(exitCode: 1, stdout: "", stderr: "sudo: a terminal is required to read the password\n")
                case ["outdated", "--json=v2", "--greedy", "--greedy-latest", "--greedy-auto-updates"]:
                    return ProcessResult(exitCode: 0, stdout: #"{"formulae":[],"casks":[]}"#, stderr: "")
                case ["outdated"], ["outdated", "-g", "--json"]:
                    return ProcessResult(exitCode: 0, stdout: request.arguments.count == 1 ? "" : "{}", stderr: "")
                default:
                    throw StubError.unexpected(request.arguments)
                }
            },
            events: { .failure(StubError.unexpected($0.arguments)) }
        )
        let harness = makeScanStoreRuntimeHarness(runner: runner, sudoPolicyDistrust: { .noProofOfSafety },
                                                  masPasswordPromptsAllowed: { false })
        harness.store.masOutdated = [MasOutdatedApp(appStoreID: "123", name: "Example App", installedVersion: "1", currentVersion: "2")]
        let boards = BoardRecorder(harness.store)

        await harness.store.runUpdate(targetKeys: Set(harness.store.allItems.map(\.key)))

        #expect(!runner.requests.contains { $0.executableURL.path == "/usr/bin/sudo" })
        #expect(boards.seen.contains { $0.lanes[.appStore] == .heldForPassword })
        let entry = harness.store.runReport?.entries.first
        #expect(entry?.wasHeldForPassword == true)
        withLanguage(.pl) { #expect(entry?.note(undo: nil) == Self.heldNotePL) }
    }

    @Test func theRowSaysItIsSkippedForThePassword() {
        withLanguage(.pl) { #expect(UpdateRunRowStatus.heldForPassword.title(isStopping: false) == "pomijam — wymaga hasła") }
        withLanguage(.en) { #expect(UpdateRunRowStatus.heldForPassword.laneTitle(isStopping: true) == "skipping — needs a password") }
    }

    // MARK: Fixtures

    private static func keys(_ tokens: String...) -> Set<String> {
        Set(tokens.map { UpdatePlanner.key(name: $0, kind: .cask) })
    }

    /// `serial` casks declare a `pkg` (they may ask); `plain` ones install an app only.
    private static func harness(
        serial: [String], plain: [String], distrust: @escaping @MainActor () -> SudoPolicyDistrust?
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
        let harness = makeScanStoreRuntimeHarness(runner: runner, sudoPolicyDistrust: distrust)
        harness.store.brewOutdated = BrewOutdated(
            formulae: [],
            casks: (serial + plain).map { BrewOutdatedItem(name: $0, installedVersions: ["1"], currentVersion: "2") }
        )
        for token in serial + plain {
            harness.store.caskDownloads[token] = CaskDownloadInfo(token: token, url: nil, sha256: nil)
        }
        for token in plain {
            harness.store.caskProfiles[token] = CaskArtifactProfile(token: token, artifacts: [CaskArtifact(kind: .app, names: ["\(token).app"])])
        }
        for token in serial {
            harness.store.caskProfiles[token] = CaskArtifactProfile(token: token, artifacts: [CaskArtifact(kind: .pkg, names: ["\(token).pkg"])])
        }
        return (harness, runner)
    }
}

private extension ScanStoreRuntimeProcessRunner {
    func upgraded(_ token: String) -> Bool {
        requests.contains { $0.arguments.starts(with: ["upgrade", "--cask"]) && $0.arguments.last == token }
    }
}

/// The operations a cask run journals and the download gate's defaults, put back after the test.
@MainActor
private final class RunCleanup {
    private let baseline = Set(UpdateOperationStore.shared.operations().map(\.id))
    private let gateDefaults = ScanStoreRuntimeDownloadGateDefaults()

    func restore() {
        removeScanStoreRuntimeOperations(createdAfter: baseline)
        gateDefaults.restore()
    }
}

@MainActor
private final class BoardRecorder {
    private(set) var seen: [UpdateRunBoard] = []
    private var watch: AnyCancellable?

    init(_ store: ScanStore) {
        watch = store.$runBoard.sink { [weak self] in self?.seen.append($0) }
    }
}

@MainActor
private final class Answers {
    private var answers: [SudoPolicyDistrust?]
    private(set) var asked = 0

    init(_ answers: [SudoPolicyDistrust?]) { self.answers = answers }

    func next() -> SudoPolicyDistrust? {
        asked += 1
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}
