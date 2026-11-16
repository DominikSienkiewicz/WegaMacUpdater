import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

/// XCTest runs these one after another, so switching the process-wide language here cannot race
/// another test; each switch is undone before the helper returns.
@MainActor
final class CleanupPresentationTests: XCTestCase {
    private typealias Fixture = CleanupPresentationFixtures

    func testSectionsGroupCopiesByToolInStageOneOrder() throws {
        let report = Fixture.report(
            findings: [
                Fixture.claudeLink, Fixture.claudeCask, Fixture.gitSystem, Fixture.gitHomebrew,
                Fixture.claudeOldVersion, Fixture.claudeAppManaged, Fixture.fnmStale, Fixture.fnmKept,
            ],
            skippedProtected: ["/Users/cleanup-test/Documents/bin"]
        )

        try withLanguage(.pl) {
            let sections = CleanupPresentation.sections(report, home: Fixture.home)

            XCTAssertEqual(sections.map(\.title), [
                tr("Wiele kopii tego samego narzędzia"), tr("Homebrew"), tr("Menedżery wersji"), tr("Gradle"), tr("JetBrains"),
                tr("Stan powłok"), tr("PATH"), tr("Pominięte lokalizacje chronione"), tr("Wpisy w „Pliki i foldery”"),
            ])
            XCTAssertEqual(sections.map(\.kind), [
                .duplicates, .homebrew, .runtimes, .gradle, .jetBrains, .shellState, .pathHygiene, .protectedLocations, .filesAndFolders,
            ])
            let copies = try XCTUnwrap(sections.first).rows
            XCTAssertEqual(copies.map(\.title), [
                "~/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "~/.local/share/claude/versions/2.1.322",
                "~/Library/Application Support/Claude/claude-code",
                "/opt/homebrew/bin/git",
                "/usr/bin/git",
            ])
            XCTAssertEqual(copies.map(\.groupHeader), ["claude", nil, nil, nil, "git", nil])
            XCTAssertEqual(copies.map(\.status), ["aktywna", "przesłonięta", "nieużywana", "zarządzana przez aplikację", "aktywna", "oczekiwana"])
            XCTAssertEqual(sections[5].rows.map(\.title), ["~/.local/state/fnm_multishells", "~/.local/state/fnm_multishells"])
            XCTAssertEqual(sections[5].rows.map(\.findingID), [Fixture.fnmStale.id, Fixture.fnmKept.id])
            XCTAssertNotEqual(Fixture.fnmStale.id, Fixture.fnmKept.id, "stale and kept entries of one directory are two rows")
            XCTAssertEqual(sections[7].rows.map(\.title), ["~/Documents/bin"])
            XCTAssertEqual(sections[7].rows.map(\.status), ["pominięta (lokalizacja chroniona)"])
            XCTAssertEqual(
                sections[8].rows.map(\.title), ["claude", "~/Library/Application Support/Claude/claude-code"],
                "with the map off, the tool with two copies and the app's copy may have entries"
            )
            XCTAssertEqual(sections[8].rows.map(\.findingID), [nil, nil])
            XCTAssertEqual(sections[8].notes.count, 3, "the mechanism in two sentences, then where to turn the map on")
        }
    }

    func testSectionsWithoutFindingsStillExplainWhatWasChecked() {
        let report = Fixture.report(findings: [], skippedProtected: [])

        withLanguage(.pl) {
            let sections = CleanupPresentation.sections(report, home: Fixture.home)

            XCTAssertEqual(
                sections.map(\.kind), [.duplicates, .homebrew, .runtimes, .gradle, .jetBrains, .shellState, .pathHygiene, .filesAndFolders]
            )
            XCTAssertTrue(sections.allSatisfy { $0.rows.isEmpty && !$0.notes.isEmpty })
        }
    }

    func testDetectorNotesAndAnApproximatePathAreShownWhereTheyApply() throws {
        let homebrew = CleanupDetectorNote(detector: .homebrew, kind: .homebrewUnavailable)
        let shell = CleanupDetectorNote(detector: .shellState, kind: .failed)
        let report = Fixture.report(
            findings: [Fixture.claudeCask], notes: [homebrew, shell], path: Fixture.approximatePath
        )

        try withLanguage(.pl) {
            let sections = CleanupPresentation.sections(report, home: Fixture.home)
            let copies = try XCTUnwrap(sections.first { $0.kind == .duplicates })
            let shellState = try XCTUnwrap(sections.first { $0.kind == .shellState })

            XCTAssertTrue(copies.notes.contains(CleanupPresentation.noteText(homebrew)))
            XCTAssertTrue(copies.notes.contains { $0.contains(tr("przybliżony")) })
            XCTAssertEqual(shellState.notes, [CleanupPresentation.noteText(shell)])
        }
    }

    func testExcludedRowsHaveNoButton() {
        let dependency = CleanupFinding(
            .pathDuplicates, tool: "python3", path: "/usr/local/bin/python3",
            source: .homebrewFormula(name: "python@3.12"), status: .dependency(["awscli"]),
            reason: .requiredBy(["awscli"]), action: .none, bucket: .excluded
        )
        let excludedWithAnAction = CleanupFinding(
            .shellState, tool: "fnm", path: "/Users/cleanup-test/.local/state/fnm_multishells",
            source: nil, status: .info, reason: .keptSinceBoot(count: 3),
            action: .trash([Fixture.url("/Users/cleanup-test/.local/state/fnm_multishells")]), bucket: .excluded
        )
        let report = Fixture.report(findings: [Fixture.gitSystem, Fixture.claudeAppManaged, dependency, excludedWithAnAction])

        withLanguage(.pl) {
            let rows = CleanupPresentation.sections(report, home: Fixture.home).flatMap(\.rows)

            XCTAssertEqual(
                rows.compactMap(\.findingID),
                [Fixture.gitSystem, Fixture.claudeAppManaged, dependency, excludedWithAnAction].map(\.id)
            )
            for row in rows {
                XCTAssertNil(row.button, row.title)
                XCTAssertEqual(row.note, tr("tylko informacja"), row.title)
            }
        }
    }

    func testCommandRowsOfferCopyNotExecute() throws {
        let npm = CleanupFinding(
            .pathDuplicates, tool: "x", path: "/opt/homebrew/bin/x", source: .packageManager(.npm),
            status: .shadowed, reason: .shadowedBy(path: "/Users/cleanup-test/.local/bin/x"),
            action: .command("npm uninstall -g x"), bucket: .needsDecision
        )
        let instruction = CleanupFinding(
            .pathDuplicates, tool: "x", path: "/Users/cleanup-test/.local/bin/x", source: .standalone,
            status: .shadowed, reason: .shadowedBy(path: "/opt/homebrew/bin/x"),
            action: .instruction(.removeWithCreatingTool), bucket: .needsDecision
        )
        let report = Fixture.report(findings: [npm, instruction, Fixture.claudeCask, Fixture.claudeOldVersion, Fixture.fnmStale])

        try withLanguage(.pl) {
            let rows = CleanupPresentation.sections(report, home: Fixture.home).flatMap(\.rows)
            func row(_ finding: CleanupFinding) throws -> CleanupPresentation.Row {
                try XCTUnwrap(rows.first { $0.findingID == finding.id })
            }

            XCTAssertEqual(try row(npm).button, .copyCommand("npm uninstall -g x"))
            XCTAssertEqual(try row(npm).note, "npm uninstall -g x")
            XCTAssertNil(try row(instruction).button)
            XCTAssertEqual(try row(instruction).note, CleanupPresentation.instructionText(.removeWithCreatingTool))
            XCTAssertEqual(try row(Fixture.claudeCask).button, .brew)
            XCTAssertEqual(try row(Fixture.claudeOldVersion).button, .trash)
            XCTAssertEqual(try row(Fixture.fnmStale).button, .trash)
        }
    }

    func testHeadlineFormatsBothTotals() {
        let totals = CleanupTotals(safe: 16_900_000_000, needsDecision: 900_000_000)
        let safe = ByteCountFormatter.string(fromByteCount: 16_900_000_000, countStyle: .file)
        let needsDecision = ByteCountFormatter.string(fromByteCount: 900_000_000, countStyle: .file)

        XCTAssertEqual(
            withLanguage(.pl) { CleanupPresentation.headline(totals) },
            "Do odzyskania: \(safe) bezpiecznie · \(needsDecision) wymaga decyzji"
        )
        XCTAssertEqual(
            withLanguage(.en) { CleanupPresentation.headline(totals) },
            "Reclaimable: \(safe) safely · \(needsDecision) needs a decision"
        )
    }

    func testEveryPresentationStringIsTranslated() {
        let statuses: [CleanupStatus] = [
            .active, .shadowed, .unused, .stale, .inUse([Fixture.processWithArguments]), .expected,
            .appManaged, .dependency(["gh"]), .brokenLink, .skippedProtected, .info,
        ]
        let reasons: [CleanupReason] = [
            .olderVersion(current: "2.1.325"), .newerVersion(current: "2.1.325"), .shadowedBy(path: "~/.local/bin/claude"),
            .systemCopy,
            .managedByApp(owner: "Claude"), .staleSinceBoot(count: 2), .keptSinceBoot(count: 3),
            .unknownVersionDirectory, .currentVersion, .protectedLocation, .brokenLink, .requiredBy(["gh"]),
        ]
        let instructions: [CleanupInstruction] = [
            .removeWithCreatingTool, .removeAppLinkWithAdminRights(link: "/usr/local/bin/code"),
        ]
        let notes = [
            CleanupDetectorNote(detector: .homebrew, kind: .homebrewUnavailable),
            CleanupDetectorNote(detector: .homebrew, kind: .failed),
            CleanupDetectorNote(detector: .pathDuplicates, kind: .failed),
            CleanupDetectorNote(detector: .source, kind: .failed),
            CleanupDetectorNote(detector: .versionDirectories, kind: .failed),
            CleanupDetectorNote(detector: .shellState, kind: .failed),
        ]

        XCTAssertEqual(withLanguage(.pl) { statuses.map(CleanupPresentation.statusText) }, [
            "aktywna", "przesłonięta", "nieużywana", "nieaktualny", "w użyciu", "oczekiwana",
            "zarządzana przez aplikację", "zależność", "uszkodzone dowiązanie",
            "pominięta (lokalizacja chroniona)", "informacja",
        ])
        assertTranslated(statuses, CleanupPresentation.statusText)
        assertTranslated([.pinned(by: ["~/p/.nvmrc"]), .recentUpgrade(until: Date())], CleanupPresentation.statusText)
        assertTranslated([
            .homebrewLeftovers(items: 3), .homebrewKeptVersions(count: 2), .installedOnlyAsDependency, .recentlyUpgraded,
            .notRequiredByProjects, .requiredByProjects, .unusedGradleDistribution, .unreferencedJDK(major: 17),
            .systemJDK(major: 21), .ideVersionNotInstalled(installed: ["2025.2"]), .ideNotFound,
            .newerThanInstalledIDE(installed: ["2025.2"]),
        ], CleanupPresentation.reasonText)
        assertTranslated(
            [.dryRunFailed, .noProjectRoots, .projectWalkTruncated, .unrecognisedIDEInstall]
                .map { CleanupDetectorNote(detector: .jetBrains, kind: $0) },
            CleanupPresentation.noteText
        )
        assertTranslated(
            [.runtimeVersions, .jetBrains].map { CleanupDetectorNote(detector: $0, kind: .failed) }, CleanupPresentation.noteText
        )
        assertTranslated([CleanupPresentation.ButtonKind.brewCleanup], CleanupPresentation.buttonTitle)
        assertTranslated(reasons, CleanupPresentation.reasonText)
        assertTranslated(instructions, CleanupPresentation.instructionText)
        assertTranslated(notes, CleanupPresentation.noteText)
    }

    func testStalePathSnapshotSuggestsRefresh() throws {
        let now = Fixture.now
        let eightDaysOld = Fixture.shellPath(capturedAt: now.addingTimeInterval(-8 * 86_400))
        let sixDaysOld = Fixture.shellPath(capturedAt: now.addingTimeInterval(-6 * 86_400))

        try withLanguage(.pl) {
            let refresh = tr("Odczyt ma ponad 7 dni — odczytaj PATH ponownie.")
            let stale = CleanupPresentation.pathHint(eightDaysOld, now: now)
            let fresh = CleanupPresentation.pathHint(sixDaysOld, now: now)

            XCTAssertTrue(stale.contains(refresh), stale)
            XCTAssertTrue(stale.contains(CleanupPresentation.dateText(try XCTUnwrap(eightDaysOld.capturedAt))), stale)
            XCTAssertEqual(fresh, trf("z powłoki %@, %@", "zsh", CleanupPresentation.dateText(try XCTUnwrap(sixDaysOld.capturedAt))))
            XCTAssertFalse(fresh.contains(refresh))
            XCTAssertEqual(CleanupPresentation.pathHint(Fixture.approximatePath, now: now), tr("przybliżony"))
            XCTAssertEqual(CleanupPresentation.pathHint(nil, now: now), tr("przybliżony"))
            XCTAssertEqual(tr("przybliżony"), "przybliżony")
        }
        XCTAssertEqual(withLanguage(.en) { CleanupPresentation.pathHint(Fixture.approximatePath, now: now) }, "approximate")
    }

    func testConfirmationSpellsTheExactActionPathSizeAndRisk() {
        let caskReport = Fixture.report(findings: [Fixture.claudeCask])

        withLanguage(.pl) {
            let cask = CleanupPresentation.confirmation(for: Fixture.claudeCask, home: Fixture.home)
            XCTAssertEqual(cask.action, CleanupActionText.command(for: .uninstallCask("claude-code")))
            XCTAssertEqual(cask.action, "brew uninstall --cask -- claude-code")
            let formula = CleanupPresentation.confirmation(for: Fixture.ghFormula, home: Fixture.home)
            XCTAssertEqual(formula.action, CleanupActionText.command(for: .uninstallFormula("gh")), "the sheet shows what BrewService runs")
            XCTAssertEqual(formula.action, "brew uninstall --formula -- gh")
            XCTAssertTrue(CleanupReportRenderer.text(
                caskReport, home: Fixture.home,
                reasonText: CleanupPresentation.reasonText, statusText: CleanupPresentation.statusText
            ).contains(cask.action), "the sheet spells the command as the text export does")
            XCTAssertEqual(cask.paths, ["/opt/homebrew/bin/claude"])
            XCTAssertEqual(cask.sizeText, ByteCountFormatter.string(fromByteCount: 300_000_000, countStyle: .file))
            XCTAssertEqual(cask.reason, CleanupPresentation.reasonText(.shadowedBy(path: "~/.local/bin/claude")))
            XCTAssertEqual(cask.risk, trf("Ryzyko: %@", tr("niskie")))
            XCTAssertEqual(cask.confirmTitle, tr("Odinstaluj"))

            let batch = CleanupPresentation.confirmation(for: Fixture.fnmStale, home: Fixture.home)
            XCTAssertEqual(batch.paths, ["~/.local/state/fnm_multishells"])
            XCTAssertEqual(batch.action, trf("Przeniesienie do Kosza — liczba wpisów: %@, folder: %@", "2", "~/.local/state/fnm_multishells"))
            XCTAssertEqual(batch.confirmTitle, tr("Przenieś do Kosza"))

            let inUse = CleanupPresentation.confirmation(for: Fixture.claudeInUse, home: Fixture.home)
            XCTAssertEqual(inUse.processes, ["claude (PID 812): claude --chrome-native-host --token=secret-value"])
            XCTAssertEqual(inUse.risk, trf("Ryzyko: %@", tr("wysokie")))
        }
    }

    func testTheSheetAsksForAcknowledgementOnlyAfterItsOwnRequest() {
        let processes = [Fixture.processWithArguments]
        let stale = CleanupRemovalOutcome.needsInUseAcknowledgement(processes)

        withLanguage(.pl) {
            XCTAssertEqual(CleanupPresentation.sheetState(submitted: false, phase: .idle, outcome: stale), .ready)
            XCTAssertEqual(CleanupPresentation.sheetState(submitted: false, phase: .idle, outcome: .removed), .ready)
            XCTAssertEqual(
                CleanupPresentation.sheetState(submitted: true, phase: .removing(findingID: "x"), outcome: .removed),
                .working, "an outcome left by an earlier removal does not close this sheet"
            )
            XCTAssertEqual(CleanupPresentation.sheetState(submitted: true, phase: .idle, outcome: stale), .needsAcknowledgement(processes))
            XCTAssertEqual(CleanupPresentation.sheetState(submitted: true, phase: .scanning, outcome: .removed), .done)
            XCTAssertEqual(
                CleanupPresentation.sheetState(submitted: true, phase: .idle, outcome: .changedSinceScan),
                .refused(CleanupPresentation.outcomeMessage(.changedSinceScan) ?? "")
            )
        }
    }

    func testInUseAcknowledgementIsSentOnlyAfterTheProcessesWereShown() {
        let finding = Fixture.claudeInUse
        let shown = CleanupPresentation.SheetState.needsAcknowledgement([Fixture.processWithArguments])

        XCTAssertFalse(CleanupPresentation.removalIntent(for: finding, state: .ready, acknowledged: true).inUseAcknowledged)
        XCTAssertFalse(CleanupPresentation.removalIntent(for: finding, state: shown, acknowledged: false).inUseAcknowledged)
        XCTAssertTrue(CleanupPresentation.removalIntent(for: finding, state: shown, acknowledged: true).inUseAcknowledged)
        XCTAssertEqual(CleanupPresentation.removalIntent(for: finding, state: shown, acknowledged: true).finding, finding)

        XCTAssertTrue(CleanupPresentation.canConfirm(.ready, phase: .idle, acknowledged: false))
        XCTAssertFalse(CleanupPresentation.canConfirm(.ready, phase: .scanning, acknowledged: false))
        XCTAssertFalse(CleanupPresentation.canConfirm(shown, phase: .idle, acknowledged: false))
        XCTAssertTrue(CleanupPresentation.canConfirm(shown, phase: .idle, acknowledged: true))
        XCTAssertFalse(CleanupPresentation.canConfirm(.refused("x"), phase: .idle, acknowledged: true))
    }

    func testRefusedRemovalsExplainTheirCause() throws {
        try withLanguage(.pl) {
            let rescan = try XCTUnwrap(CleanupPresentation.outcomeMessage(.changedSinceScan))
            let dependents = try XCTUnwrap(CleanupPresentation.outcomeMessage(.nowRequiredBy(["awscli", "gh"])))
            let notRemovable = try XCTUnwrap(CleanupPresentation.outcomeMessage(.notRemovable))
            let failed = try XCTUnwrap(CleanupPresentation.outcomeMessage(.failed("CleanupFileSystemError.io")))

            XCTAssertTrue(rescan.contains(tr("Skanuj")), rescan)
            XCTAssertTrue(dependents.contains("awscli, gh"), dependents)
            XCTAssertEqual(Set([rescan, dependents, notRemovable, failed]).count, 4)
            XCTAssertNil(CleanupPresentation.outcomeMessage(.needsInUseAcknowledgement([Fixture.processWithArguments])))
        }
    }

    func testTextExportStartsWithTotalsNotesAndSkippedLocations() throws {
        let note = CleanupDetectorNote(detector: .homebrew, kind: .homebrewUnavailable)
        let report = Fixture.report(
            findings: [Fixture.claudeCask, Fixture.claudeInUse], notes: [note],
            skippedProtected: ["/Users/cleanup-test/Documents/bin"]
        )

        try withLanguage(.pl) {
            let text = CleanupPresentation.exportText(report, home: Fixture.home)
            let findingLines = CleanupReportRenderer.text(
                report, home: Fixture.home,
                reasonText: CleanupPresentation.reasonText, statusText: CleanupPresentation.statusText
            )
            let header = try XCTUnwrap(text.components(separatedBy: findingLines).first)

            XCTAssertTrue(text.hasSuffix(findingLines))
            XCTAssertEqual(header.components(separatedBy: "\n").first, trf("Porządki — raport z %@", CleanupPresentation.dateText(Fixture.now)))
            XCTAssertTrue(header.contains(CleanupPresentation.headline(report.totals)), header)
            XCTAssertTrue(header.contains(CleanupPresentation.noteText(note)), header)
            XCTAssertTrue(header.contains("- ~/Documents/bin"), header)
            XCTAssertFalse(text.contains("/Users/cleanup-test"), "every path is written with ~")
            XCTAssertFalse(text.contains("secret-value"), "process arguments never reach an export")
        }
    }

    // MARK: - Space sections

    func testSectionsAppearInSidebarSketchOrder() throws {
        let report = Fixture.report(
            findings: [
                Fixture.fnmStale, Fixture.ideFolder, Fixture.gradleDistribution, Fixture.pythonUnused,
                Fixture.nodeLeftovers, Fixture.claudeCask,
            ],
            skippedProtected: ["/Users/cleanup-test/Documents/bin"]
        )
        let empty = Fixture.report(findings: [])
        let spaceKinds: [CleanupPresentation.Section.Kind] = [.homebrew, .runtimes, .gradle, .jetBrains]

        try withLanguage(.pl) {
            let sections = CleanupPresentation.sections(report, home: Fixture.home)
            XCTAssertEqual(sections.map(\.kind), [
                .duplicates, .homebrew, .runtimes, .gradle, .jetBrains, .shellState, .pathHygiene, .protectedLocations, .filesAndFolders,
            ])
            XCTAssertEqual(sections.map(\.title), [
                "Wiele kopii tego samego narzędzia", "Homebrew", "Menedżery wersji", "Gradle", "JetBrains", "Stan powłok", "PATH",
                "Pominięte lokalizacje chronione", "Wpisy w „Pliki i foldery”",
            ])

            let emptySections = CleanupPresentation.sections(empty, home: Fixture.home)
            XCTAssertEqual(
                emptySections.map(\.kind), [.duplicates, .homebrew, .runtimes, .gradle, .jetBrains, .shellState, .pathHygiene, .filesAndFolders],
                "the space sections say they found nothing; skipped protected locations appear only when there are some"
            )
            XCTAssertEqual(emptySections.filter { spaceKinds.contains($0.kind) }.map(\.notes), [
                ["Homebrew nie ma nic do sprzątnięcia."], ["Nie znaleziono nieużywanych wersji."],
                ["Nie znaleziono nieużywanych dystrybucji ani JDK."], ["Nie znaleziono katalogów starych wersji IDE."],
            ])
            let filesAndFolders = try XCTUnwrap(emptySections.last)
            XCTAssertEqual(filesAndFolders.kind, .filesAndFolders)
            XCTAssertEqual(filesAndFolders.notes.first, tr("Narzędzie wiersza poleceń nie ma pakietu aplikacji, więc macOS zapisuje zgodę na dostęp do plików osobno dla każdej ścieżki, z której zostało uruchomione."))
            XCTAssertEqual(filesAndFolders.notes.count, 3, "the mechanism in two sentences, then where to turn the map on")
            XCTAssertEqual(
                filesAndFolders.notes.last,
                tr("Mapa, która przypisuje te wpisy do konkretnych kopii, jest wyłączona. Włącz ją w Ustawieniach.")
            )
        }
        let english = withLanguage(.en) { CleanupPresentation.sections(empty, home: Fixture.home) }
        XCTAssertEqual(english.filter { spaceKinds.contains($0.kind) }.map(\.title), ["Homebrew", "Version managers", "Gradle", "JetBrains"])
        XCTAssertEqual(english.filter { spaceKinds.contains($0.kind) }.map(\.notes), [
            ["Homebrew has nothing to clean up."], ["No unused versions found."],
            ["No unused distributions or JDKs found."], ["No folders of old IDE versions found."],
        ])
    }

    func testFindingsRouteToTheirDetectorsSection() throws {
        let noRoots = CleanupDetectorNote(detector: .runtimeVersions, kind: .noProjectRoots)
        let truncated = CleanupDetectorNote(detector: .runtimeVersions, kind: .projectWalkTruncated)
        let runtimeFailed = CleanupDetectorNote(detector: .runtimeVersions, kind: .failed)
        let gradleFailed = CleanupDetectorNote(detector: .gradle, kind: .failed)
        let unrecognisedIDE = CleanupDetectorNote(detector: .jetBrains, kind: .unrecognisedIDEInstall)
        let shellFailed = CleanupDetectorNote(detector: .shellState, kind: .failed)
        let report = Fixture.report(
            findings: [
                Fixture.nodeLeftovers, Fixture.claudeCask, Fixture.pythonPinned, Fixture.ideExcluded, Fixture.gradleDistribution,
                Fixture.claudeOldVersion, Fixture.pythonUnused, Fixture.jdkUnused, Fixture.ideFolder, Fixture.fnmStale,
                Fixture.ideNewer,
            ],
            notes: [noRoots, truncated, runtimeFailed, gradleFailed, unrecognisedIDE, shellFailed]
        )

        try withLanguage(.pl) {
            let sections = CleanupPresentation.sections(report, home: Fixture.home)
            func section(_ kind: CleanupPresentation.Section.Kind) throws -> CleanupPresentation.Section {
                try XCTUnwrap(sections.first { $0.kind == kind }, "\(kind)")
            }

            XCTAssertEqual(try section(.duplicates).rows.compactMap(\.findingID), [Fixture.claudeCask.id, Fixture.claudeOldVersion.id])
            XCTAssertEqual(try section(.duplicates).notes, [], "the space detectors' notes stay out of the copies")
            XCTAssertEqual(try section(.homebrew).rows.compactMap(\.findingID), [Fixture.nodeLeftovers.id])
            XCTAssertEqual(try section(.homebrew).rows.map(\.groupHeader), ["node"])
            XCTAssertEqual(try section(.runtimes).rows.compactMap(\.findingID), [Fixture.pythonUnused.id, Fixture.pythonPinned.id])
            XCTAssertEqual(try section(.runtimes).rows.map(\.groupHeader), ["python", nil], "rows group by tool, removable first")
            XCTAssertEqual(try section(.runtimes).notes, [noRoots, truncated, runtimeFailed].map(CleanupPresentation.noteText))
            XCTAssertEqual(try section(.gradle).rows.compactMap(\.findingID), [Fixture.gradleDistribution.id, Fixture.jdkUnused.id])
            XCTAssertEqual(try section(.gradle).rows.map(\.groupHeader), ["gradle", "java"])
            XCTAssertEqual(
                try section(.gradle).notes, [noRoots, truncated, gradleFailed].map(CleanupPresentation.noteText),
                "Gradle repeats why the project walk may have missed a wrapper"
            )
            XCTAssertEqual(
                try section(.jetBrains).rows.compactMap(\.findingID), [Fixture.ideExcluded.id, Fixture.ideFolder.id, Fixture.ideNewer.id]
            )
            XCTAssertEqual(try section(.jetBrains).rows.map(\.groupHeader), ["PyCharm", "IntelliJIdea", nil])
            XCTAssertEqual(try section(.jetBrains).notes, [CleanupPresentation.noteText(unrecognisedIDE)])
            XCTAssertEqual(try section(.shellState).rows.compactMap(\.findingID), [Fixture.fnmStale.id])
            XCTAssertEqual(try section(.shellState).notes, [CleanupPresentation.noteText(shellFailed)])
            XCTAssertEqual(try section(.homebrew).rows.first?.button, .brewCleanup)
            XCTAssertEqual(try section(.runtimes).rows.first?.button, .copyCommand("uv python uninstall 3.11.9"))
            XCTAssertEqual(try section(.gradle).rows.first?.button, .trash)
        }
    }

    func testDryRunFailureNoteShowsUnderHomebrew() throws {
        let dryRunFailed = CleanupDetectorNote(detector: .homebrew, kind: .dryRunFailed)
        let unavailable = CleanupDetectorNote(detector: .homebrew, kind: .homebrewUnavailable)
        let dependencyCheckFailed = CleanupDetectorNote(detector: .homebrew, kind: .failed)
        let report = Fixture.report(findings: [Fixture.claudeCask], notes: [unavailable, dryRunFailed, dependencyCheckFailed])

        try withLanguage(.pl) {
            let sections = CleanupPresentation.sections(report, home: Fixture.home)
            let homebrew = try XCTUnwrap(sections.first { $0.kind == .homebrew })
            let copies = try XCTUnwrap(sections.first { $0.kind == .duplicates })

            XCTAssertEqual(homebrew.notes, [CleanupPresentation.noteText(dryRunFailed)], "not the empty text: the leftovers are unknown")
            XCTAssertEqual(
                copies.notes, [unavailable, dependencyCheckFailed].map(CleanupPresentation.noteText),
                "the stage-1 dependency check notes stay with the copies they concern"
            )
        }
    }

    func testJetBrainsRowsRecommendTheIdeAction() throws {
        let report = Fixture.report(findings: [Fixture.ideFolder, Fixture.ideExcluded, Fixture.gradleDistribution])
        let polish = "Zalecane: w IDE wybierz Help → Delete Leftover IDE Directories. Wega może też przenieść ten katalog do Kosza."
        let english = "Recommended: in the IDE choose Help → Delete Leftover IDE Directories. Wega can also move this folder to the Trash."

        try withLanguage(.pl) {
            let rows = CleanupPresentation.sections(report, home: Fixture.home).flatMap(\.rows)
            let folder = try XCTUnwrap(rows.first { $0.findingID == Fixture.ideFolder.id })
            let excluded = try XCTUnwrap(rows.first { $0.findingID == Fixture.ideExcluded.id })
            let distribution = try XCTUnwrap(rows.first { $0.findingID == Fixture.gradleDistribution.id })

            XCTAssertEqual(folder.button, .trash)
            XCTAssertEqual(folder.note, polish)
            XCTAssertNil(excluded.button)
            XCTAssertEqual(excluded.note, tr("tylko informacja"), "a row without a Trash button recommends nothing")
            XCTAssertEqual(distribution.button, .trash)
            XCTAssertNil(distribution.note, "only JetBrains folders have an IDE action to recommend")
        }
        let englishRows = withLanguage(.en) { CleanupPresentation.sections(report, home: Fixture.home).flatMap(\.rows) }
        XCTAssertEqual(englishRows.first { $0.findingID == Fixture.ideFolder.id }?.note, english)
    }

    /// The IDE's own action clears only folders of versions it replaced: a folder no installed IDE
    /// owns, or one newer than the installed IDE, is not its leftover, so nothing is recommended.
    func testIdeActionIsRecommendedOnlyForVersionsTheIdeReplaced() throws {
        let orphanPath = "/Users/cleanup-test/Library/Application Support/JetBrains/GoLand2024.1"
        let orphan = CleanupFinding(
            .jetBrains, tool: "GoLand", path: orphanPath, source: nil, status: .unused, reason: .ideNotFound,
            action: .trash([Fixture.url(orphanPath)]), bucket: .needsDecision, version: "2024.1"
        )
        let report = Fixture.report(findings: [Fixture.ideFolder, Fixture.ideNewer, orphan])

        try withLanguage(.pl) {
            let rows = CleanupPresentation.sections(report, home: Fixture.home).flatMap(\.rows)
            for finding in [Fixture.ideNewer, orphan] {
                let row = try XCTUnwrap(rows.first { $0.findingID == finding.id }, finding.tool)
                XCTAssertEqual(row.button, .trash, finding.tool)
                XCTAssertNil(row.note, "\(finding.reason) is no leftover the IDE action clears")
            }
            XCTAssertNotNil(rows.first { $0.findingID == Fixture.ideFolder.id }?.note)
        }
    }

    func testBrewCleanupConfirmationShowsTheExactCommand() throws {
        let report = Fixture.report(findings: [Fixture.nodeLeftovers])

        try withLanguage(.pl) {
            let confirmation = CleanupPresentation.confirmation(for: Fixture.nodeLeftovers, home: Fixture.home)
            XCTAssertEqual(confirmation.action, "brew cleanup -- node")
            XCTAssertEqual(confirmation.action, CleanupActionText.command(for: .cleanup("node")), "the sheet shows what BrewService runs")
            XCTAssertEqual(confirmation.action, (["brew"] + BrewService.cleanupPackageArguments(name: "node")).joined(separator: " "))
            XCTAssertEqual(confirmation.confirmTitle, "Posprzątaj")
            XCTAssertEqual(confirmation.paths, ["/opt/homebrew/Cellar/node"])
            XCTAssertEqual(confirmation.reason, CleanupPresentation.reasonText(.homebrewLeftovers(items: 2)))

            let row = try XCTUnwrap(CleanupPresentation.sections(report, home: Fixture.home).flatMap(\.rows).first)
            XCTAssertEqual(row.findingID, Fixture.nodeLeftovers.id)
            XCTAssertEqual(row.button, .brewCleanup)
            XCTAssertEqual(CleanupPresentation.buttonTitle(.brewCleanup), "Posprzątaj…")
        }
        let english = withLanguage(.en) {
            (
                confirmation: CleanupPresentation.confirmation(for: Fixture.nodeLeftovers, home: Fixture.home),
                button: CleanupPresentation.buttonTitle(.brewCleanup)
            )
        }
        XCTAssertEqual(english.confirmation.confirmTitle, "Clean up", "the Logs view's \"Clear\" must not label a Homebrew clean-up")
        XCTAssertEqual(english.confirmation.action, "brew cleanup -- node")
        XCTAssertEqual(english.button, "Clean up…")
    }

    // MARK: - Helpers

    private func withLanguage<T>(_ language: AppLanguage, _ body: () throws -> T) rethrows -> T {
        let previous = LocalizedStrings.current
        LocalizedStrings.current = language
        defer { LocalizedStrings.current = previous }
        return try body()
    }

    private func assertTranslated<Value>(
        _ values: [Value], _ text: (Value) -> String, file: StaticString = #filePath, line: UInt = #line
    ) {
        for value in values {
            let polish = withLanguage(.pl) { text(value) }
            let english = withLanguage(.en) { text(value) }
            XCTAssertFalse(polish.isEmpty, "\(value)", file: file, line: line)
            XCTAssertNotEqual(polish, english, "\(value) has no English text", file: file, line: line)
        }
    }
}

private enum CleanupPresentationFixtures {
    static let home = URL(filePath: "/Users/cleanup-test", directoryHint: .isDirectory)
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let approximatePath = CleanupPathSnapshot(
        entries: ["/usr/bin", "/bin"], ignoredEntries: [], shell: nil, capturedAt: nil, isApproximate: true
    )

    static let processWithArguments = CleanupProcess(
        pid: 812, name: "claude",
        executablePath: "/Users/cleanup-test/.local/share/claude/versions/2.1.318/claude",
        arguments: ["claude", "--chrome-native-host", "--token=secret-value"]
    )

    static let claudeLink = CleanupFinding(
        .pathDuplicates, tool: "claude", path: "/Users/cleanup-test/.local/bin/claude",
        source: .nativeVersionDirectory(tool: "claude"), status: .active, reason: .currentVersion,
        action: .none, bucket: .excluded, version: "2.1.325"
    )
    static let claudeCask = CleanupFinding(
        .pathDuplicates, tool: "claude", path: "/opt/homebrew/bin/claude", source: .homebrewCask(token: "claude-code"),
        status: .shadowed, reason: .shadowedBy(path: "/Users/cleanup-test/.local/bin/claude"),
        action: .brew(.uninstallCask("claude-code")), bucket: .safe, version: "2.1.311", size: 300_000_000
    )
    static let ghFormula = CleanupFinding(
        .pathDuplicates, tool: "gh", path: "/opt/homebrew/bin/gh", source: .homebrewFormula(name: "gh"),
        status: .shadowed, reason: .shadowedBy(path: "/Users/cleanup-test/.local/bin/gh"),
        action: .brew(.uninstallFormula("gh")), bucket: .needsDecision, version: "2.104.0"
    )
    static let gitSystem = CleanupFinding(
        .pathDuplicates, tool: "git", path: "/usr/bin/git", source: .system, status: .expected,
        reason: .systemCopy, action: .none, bucket: .excluded
    )
    static let gitHomebrew = CleanupFinding(
        .pathDuplicates, tool: "git", path: "/opt/homebrew/bin/git", source: .homebrewFormula(name: "git"),
        status: .active, reason: .currentVersion, action: .none, bucket: .excluded, version: "2.47.0"
    )
    static let claudeOldVersion = CleanupFinding(
        .versionDirectories, tool: "claude", path: "/Users/cleanup-test/.local/share/claude/versions/2.1.322",
        source: .nativeVersionDirectory(tool: "claude"), status: .unused, reason: .olderVersion(current: "2.1.325"),
        action: .trash([url("/Users/cleanup-test/.local/share/claude/versions/2.1.322")]), bucket: .safe,
        version: "2.1.322", size: 307_000_000
    )
    static let claudeInUse = CleanupFinding(
        .versionDirectories, tool: "claude", path: "/Users/cleanup-test/.local/share/claude/versions/2.1.318",
        source: .nativeVersionDirectory(tool: "claude"), status: .inUse([processWithArguments]),
        reason: .olderVersion(current: "2.1.325"),
        action: .trash([url("/Users/cleanup-test/.local/share/claude/versions/2.1.318")]), bucket: .needsDecision,
        version: "2.1.318", size: 307_000_000, risk: .high
    )
    static let claudeAppManaged = CleanupFinding(
        .versionDirectories, tool: "Claude", path: "/Users/cleanup-test/Library/Application Support/Claude/claude-code",
        source: .appManaged(owner: "Claude"), status: .appManaged, reason: .managedByApp(owner: "Claude"),
        action: .none, bucket: .excluded, size: 680_000_000
    )
    static let fnmStale = CleanupFinding(
        .shellState, tool: "fnm", path: "/Users/cleanup-test/.local/state/fnm_multishells", source: nil,
        status: .stale, reason: .staleSinceBoot(count: 2),
        action: .trashBatch(
            parent: url("/Users/cleanup-test/.local/state/fnm_multishells"),
            entries: [
                url("/Users/cleanup-test/.local/state/fnm_multishells/101_1700000000000"),
                url("/Users/cleanup-test/.local/state/fnm_multishells/102_1700000000001"),
            ]
        ),
        bucket: .safe, size: 8192
    )
    static let fnmKept = CleanupFinding(
        .shellState, tool: "fnm", path: "/Users/cleanup-test/.local/state/fnm_multishells", source: nil,
        status: .info, reason: .keptSinceBoot(count: 3), action: .none, bucket: .excluded
    )

    static let nodeLeftovers = CleanupFinding(
        .homebrew, tool: "node", path: "/opt/homebrew/Cellar/node", source: .homebrewFormula(name: "node"),
        status: .unused, reason: .homebrewLeftovers(items: 2), action: .brew(.cleanup("node")), bucket: .needsDecision,
        size: 120_000_000
    )
    static let pythonUnused = CleanupFinding(
        .runtimeVersions, tool: "python", path: "/Users/cleanup-test/.local/share/uv/python/cpython-3.11.9-macos-aarch64-none",
        source: .versionManager(.uv), status: .unused, reason: .notRequiredByProjects,
        action: .command("uv python uninstall 3.11.9"), bucket: .needsDecision, version: "3.11.9", risk: .medium
    )
    static let pythonPinned = CleanupFinding(
        .runtimeVersions, tool: "python", path: "/Users/cleanup-test/.local/share/uv/python/cpython-3.12.4-macos-aarch64-none",
        source: .versionManager(.uv), status: .pinned(by: ["/Users/cleanup-test/Dev/app/.python-version"]),
        reason: .requiredByProjects, action: .command("uv python uninstall 3.12.4"), bucket: .excluded,
        version: "3.12.4", risk: .medium
    )
    static let gradleDistribution = CleanupFinding(
        .gradle, tool: "gradle", path: "/Users/cleanup-test/.gradle/wrapper/dists/gradle-8.5-bin", source: nil,
        status: .unused, reason: .unusedGradleDistribution,
        action: .trash([url("/Users/cleanup-test/.gradle/wrapper/dists/gradle-8.5-bin")]), bucket: .safe, version: "8.5"
    )
    static let jdkUnused = CleanupFinding(
        .gradle, tool: "java", path: "/Users/cleanup-test/.gradle/jdks/eclipse_adoptium-17-aarch64-os_x.2", source: nil,
        status: .unused, reason: .unreferencedJDK(major: 17),
        action: .trash([url("/Users/cleanup-test/.gradle/jdks/eclipse_adoptium-17-aarch64-os_x.2")]), bucket: .needsDecision,
        version: "17"
    )
    static let ideFolder = CleanupFinding(
        .jetBrains, tool: "IntelliJIdea", path: "/Users/cleanup-test/Library/Application Support/JetBrains/IntelliJIdea2024.3",
        source: nil, status: .unused, reason: .ideVersionNotInstalled(installed: ["2025.2"]),
        action: .trash([url("/Users/cleanup-test/Library/Application Support/JetBrains/IntelliJIdea2024.3")]), bucket: .safe,
        version: "2024.3"
    )
    static let ideNewer = CleanupFinding(
        .jetBrains, tool: "IntelliJIdea", path: "/Users/cleanup-test/Library/Caches/JetBrains/IntelliJIdea2025.3",
        source: nil, status: .unused, reason: .newerThanInstalledIDE(installed: ["2025.2"]),
        action: .trash([url("/Users/cleanup-test/Library/Caches/JetBrains/IntelliJIdea2025.3")]), bucket: .needsDecision,
        version: "2025.3"
    )
    static let ideExcluded = CleanupFinding(
        .jetBrains, tool: "PyCharm", path: "/Users/cleanup-test/Library/Application Support/JetBrains/PyCharm2025.2",
        source: nil, status: .info, reason: .newerThanInstalledIDE(installed: ["2025.1"]),
        action: .trash([url("/Users/cleanup-test/Library/Application Support/JetBrains/PyCharm2025.2")]), bucket: .excluded,
        version: "2025.2"
    )

    static func url(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .notDirectory)
    }

    static func shellPath(capturedAt: Date) -> CleanupPathSnapshot {
        CleanupPathSnapshot(
            entries: ["/Users/cleanup-test/.local/bin", "/opt/homebrew/bin", "/usr/bin"], ignoredEntries: [],
            shell: "zsh", capturedAt: capturedAt, isApproximate: false
        )
    }

    static func report(
        findings: [CleanupFinding], notes: [CleanupDetectorNote] = [], skippedProtected: [String] = [],
        path: CleanupPathSnapshot = shellPath(capturedAt: now)
    ) -> CleanupReport {
        CleanupReport(createdAt: now, path: path, findings: findings, notes: notes, skippedProtected: skippedProtected)
    }
}

private extension CleanupFinding {
    /// A finding whose real path is its path; the identity is a fixed value, never read here.
    init(
        _ detector: CleanupDetectorID, tool: String, path: String, source: CleanupSource?,
        status: CleanupStatus, reason: CleanupReason, action: CleanupAction, bucket: CleanupBucket,
        version: String? = nil, size: Int64? = nil, risk: CleanupRisk = .low
    ) {
        let url = CleanupPresentationFixtures.url(path)
        self.init(
            detector: detector, tool: tool, path: url, realpath: url, source: source,
            version: version, size: size, status: status, reason: reason, action: action, risk: risk,
            bucket: bucket, identity: CleanupFileIdentity(device: 1, inode: 42)
        )
    }
}
