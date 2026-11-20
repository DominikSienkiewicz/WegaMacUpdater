import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

/// The "keep this copy" choice on screen: the radio state, the kept and undecided notes, the
/// buttons the other copies get, the takeover line and the Files and Folders labels.
extension CleanupPresentationTests {
    private typealias Keep = CleanupKeepFixtures
    private typealias Row = CleanupPresentation.Row

    private static let keepHome = URL(filePath: "/Users/cleanup-test", directoryHint: .isDirectory)

    private func rows(_ report: CleanupReport, of kind: CleanupPresentation.Section.Kind = .duplicates) -> [Row] {
        CleanupPresentation.sections(report, home: Self.keepHome, tccMapEnabled: true).first { $0.kind == kind }?.rows ?? []
    }

    private func row(_ id: String, in rows: [Row]) throws -> Row {
        try XCTUnwrap(rows.first { $0.findingID == id }, id)
    }

    private static let loneGit = CleanupFinding(
        detector: .pathDuplicates, tool: "git", path: URL(filePath: "/opt/homebrew/bin/git"), realpath: nil,
        source: .homebrewFormula(name: "git"), version: "2.47.0", size: nil, status: .active, reason: .currentVersion,
        action: .none, risk: .low, bucket: .excluded, identity: nil
    )

    func testKeptRowSaysItStaysAndOffersNoButton() throws {
        try withLanguage(.pl) {
            let byDefault = rows(Keep.report(extra: [Self.loneGit]))
            let formula = try row(Keep.formula.id, in: byDefault)
            let app = try row(Keep.appLink.id, in: byDefault)
            XCTAssertEqual(formula.keep, .kept)
            XCTAssertEqual(formula.note, "zostaje")
            XCTAssertNil(formula.button)
            XCTAssertEqual(app.keep, .notKept)
            XCTAssertEqual(app.button, .uninstallApp(name: "Ollama", bundle: Keep.bundle))
            XCTAssertEqual(app.button.map(CleanupPresentation.buttonTitle), "Odinstaluj Ollama…")
            XCTAssertNil(try row(Self.loneGit.id, in: byDefault).keep, "a copy without a choice has no radio")

            let moved = rows(Keep.report(choices: Keep.keepLink))
            XCTAssertEqual(try row(Keep.formula.id, in: moved).keep, .notKept)
            XCTAssertEqual(try row(Keep.formula.id, in: moved).button, .brew)
            XCTAssertEqual(try row(Keep.appLink.id, in: moved).keep, .kept)
            XCTAssertEqual(try row(Keep.appLink.id, in: moved).note, "zostaje")
            XCTAssertNil(try row(Keep.appLink.id, in: moved).button)
        }
    }

    func testUndecidedRowsOfferOnlyTheChoice() throws {
        try withLanguage(.pl) {
            let undecided = rows(Keep.report(approximate: true))
            for id in [Keep.formula.id, Keep.appLink.id] {
                let row = try row(id, in: undecided)
                XCTAssertEqual(row.keep, .undecided, id)
                XCTAssertNil(row.button, id)
                XCTAssertEqual(row.note, "wybierz kopię, którą zostawić", id)
            }
        }
    }

    func testRemovingTheActiveCopySaysWhichCopyTakesOver() throws {
        try withLanguage(.pl) {
            let formula = try XCTUnwrap(Keep.finding(Keep.formula.id, in: Keep.report(choices: Keep.keepLink)))
            XCTAssertEqual(
                CleanupPresentation.confirmation(for: formula, home: Self.keepHome).takeover,
                "Tej kopii używa teraz Terminal. Po usunięciu użyje /usr/local/bin/ollama."
            )
            let app = try XCTUnwrap(Keep.finding(Keep.appLink.id, in: Keep.report()))
            XCTAssertNil(CleanupPresentation.confirmation(for: app, home: Self.keepHome).takeover)
        }
        let local = "/Users/cleanup-test/.local/bin/ollama"
        let inHome = CleanupFinding(
            detector: .pathDuplicates, tool: "ollama", path: URL(filePath: Keep.formulaPath), realpath: nil,
            source: .homebrewFormula(name: "ollama"), version: nil, size: 1, status: .active,
            reason: .keptInstead(path: local), action: .brew(.uninstallFormula("ollama")), risk: .low,
            bucket: .needsDecision, identity: nil,
            candidate: CleanupCandidate(
                pathRole: .active, removal: .brew(.uninstallFormula("ollama")), removalSize: 1, dependents: [], processes: [],
                keep: .notKept(keptPath: local), takesOver: local
            )
        )
        let polish = withLanguage(.pl) { CleanupPresentation.confirmation(for: inHome, home: Self.keepHome).takeover }
        let english = withLanguage(.en) { CleanupPresentation.confirmation(for: inHome, home: Self.keepHome).takeover }
        XCTAssertEqual(english, "Terminal uses this copy now. After the removal it will use ~/.local/bin/ollama.")
        XCTAssertNotEqual(polish, english)
    }

    func testBrokenLinkRowOffersTheUnlinkCommand() throws {
        let broken = CleanupFinding(
            detector: .pathDuplicates, tool: "ollama", path: URL(filePath: Keep.linkPath), realpath: nil, source: .standalone,
            version: nil, size: nil, status: .brokenLink, reason: .brokenLink, action: .command("sudo unlink /usr/local/bin/ollama"),
            risk: .low, bucket: .excluded, identity: nil
        )
        let report = CleanupReport(
            createdAt: Keep.createdAt, path: Keep.path(approximate: false), findings: [broken], notes: [], skippedProtected: []
        )
        try withLanguage(.pl) {
            let row = try row(broken.id, in: rows(report))
            XCTAssertEqual(row.button, .copyCommand("sudo unlink /usr/local/bin/ollama"))
            XCTAssertEqual(row.note, "sudo unlink /usr/local/bin/ollama")
        }
    }

    func testFilesAndFoldersLinkFollowsTheChoice() throws {
        func entry(_ copy: CleanupFinding, kind: CleanupTCCLinkKind) -> CleanupFinding {
            CleanupFinding(
                detector: .tccMap, tool: "ollama", path: copy.path, realpath: copy.realpath, source: nil, version: nil,
                size: nil, status: .info,
                reason: .tccEntry(
                    grants: [CleanupTCCGrant(service: .documents, allowed: true)],
                    link: CleanupTCCLink(findingID: copy.id, kind: kind)
                ),
                action: .none, risk: .low, bucket: .excluded, identity: nil
            )
        }
        let formulaEntry = entry(Keep.formula, kind: .activeCopy)
        let appEntry = entry(Keep.appLink, kind: .copyToRemove)
        func detail(_ entry: CleanupFinding, _ report: CleanupReport) throws -> String {
            try row(entry.id, in: rows(report, of: .filesAndFolders)).detail
        }
        try withLanguage(.pl) {
            let byDefault = Keep.report(extra: [formulaEntry, appEntry])
            XCTAssertTrue(try detail(formulaEntry, byDefault).hasSuffix("; dotyczy kopii, którą zostawiasz"))
            XCTAssertTrue(try detail(appEntry, byDefault).hasSuffix("; dotyczy kopii do usunięcia"))

            let moved = Keep.report(choices: Keep.keepLink, extra: [formulaEntry, appEntry])
            XCTAssertTrue(try detail(appEntry, moved).hasSuffix("; dotyczy kopii, którą zostawiasz"))
            XCTAssertTrue(try detail(formulaEntry, moved).hasSuffix("; dotyczy kopii do usunięcia"))
            XCTAssertTrue(
                CleanupPresentation.exportText(moved, home: Self.keepHome).contains("dotyczy kopii, którą zostawiasz"),
                "the text export names the kept copy the same way"
            )

            let undecided = Keep.report(approximate: true, extra: [formulaEntry, appEntry])
            XCTAssertTrue(try detail(formulaEntry, undecided).hasSuffix("; dotyczy aktywnej kopii"))
        }
    }

    /// The `PATH`-active copy keeps the status `active` (B5), so its processes travel with the
    /// candidate; the row and the sheet name them before the remover's own check does.
    func testNotKeptActiveCopyInUseListsItsProcessesUpFront() throws {
        let process = CleanupProcess(pid: 4242, name: "ollama", executablePath: Keep.formulaPath, arguments: ["serve"])
        let formula = Keep.formula
        let busy = CleanupFinding(
            detector: formula.detector, tool: formula.tool, path: formula.path, realpath: formula.realpath,
            source: formula.source, version: formula.version, size: nil, status: .active, reason: formula.reason,
            action: formula.action, risk: formula.risk, bucket: formula.bucket, identity: formula.identity,
            candidate: CleanupCandidate(
                pathRole: .active, removal: .brew(.uninstallFormula("ollama")), removalSize: 70_000_000, dependents: [],
                processes: [process]
            )
        )
        let report = CleanupKeepChoice.apply(Keep.keepLink, to: CleanupReport(
            createdAt: Keep.createdAt, path: Keep.path(approximate: false), findings: [busy, Keep.appLink],
            notes: [], skippedProtected: []
        ))
        let resolved = try XCTUnwrap(Keep.finding(busy.id, in: report))
        XCTAssertEqual(resolved.candidate?.keep, .notKept(keptPath: Keep.linkPath))
        XCTAssertEqual(CleanupPresentation.confirmation(for: resolved, home: Self.keepHome).processes, ["ollama (PID 4242): serve"])
        try withLanguage(.pl) {
            XCTAssertTrue(try row(busy.id, in: rows(report)).detail.hasSuffix(" · używa: ollama (PID 4242)"))
        }
    }

    func testKeptInsteadShowsTheKeptCopyWithATilde() throws {
        let local = "/Users/cleanup-test/.local/bin/ollama"
        let localCopy = CleanupFinding(
            detector: .pathDuplicates, tool: "ollama", path: URL(filePath: local), realpath: URL(filePath: local),
            source: .standalone, version: "0.40.16", size: nil, status: .shadowed, reason: .noCopyKept, action: .none,
            risk: .low, bucket: .excluded, identity: nil,
            candidate: CleanupCandidate(
                pathRole: .shadowed, removal: .trash([URL(filePath: local)]), removalSize: 1, dependents: [], processes: []
            )
        )
        let report = CleanupKeepChoice.apply(["ollama": CleanupKeptCopy(path: local, source: .standalone)], to: CleanupReport(
            createdAt: Keep.createdAt, path: Keep.path(approximate: false), findings: [Keep.formula, localCopy],
            notes: [], skippedProtected: []
        ))
        let formula = try XCTUnwrap(Keep.finding(Keep.formula.id, in: report))
        XCTAssertEqual(formula.reason, .keptInstead(path: local))
        try withLanguage(.pl) {
            XCTAssertEqual(CleanupPresentation.confirmation(for: formula, home: Self.keepHome).reason, "zostawiasz ~/.local/bin/ollama")
            XCTAssertTrue(try row(Keep.formula.id, in: rows(report)).detail.hasSuffix(" · zostawiasz ~/.local/bin/ollama"))
        }
    }

    func testKeepControlTextsAreTranslated() {
        let row = Row(
            findingID: "D1:active:/opt/homebrew/bin/ollama", groupHeader: nil, bucket: .excluded, status: "aktywna",
            title: "/opt/homebrew/bin/ollama", detail: "", sizeText: nil, button: nil, note: nil, keep: .kept
        )
        XCTAssertEqual(withLanguage(.pl) { CleanupPresentation.keepTitle }, "zostaw")
        XCTAssertEqual(withLanguage(.en) { CleanupPresentation.keepTitle }, "keep")
        XCTAssertEqual(
            withLanguage(.pl) { CleanupPresentation.keepAccessibilityLabel(for: row) }, "Zostaw /opt/homebrew/bin/ollama"
        )
        XCTAssertEqual(
            withLanguage(.en) { CleanupPresentation.keepAccessibilityLabel(for: row) }, "Keep /opt/homebrew/bin/ollama"
        )
        XCTAssertEqual(withLanguage(.en) { rows(Keep.report()).first?.note }, "stays")
        XCTAssertEqual(
            withLanguage(.en) { rows(Keep.report(approximate: true)).first?.note }, "choose the copy to keep"
        )
    }
}
