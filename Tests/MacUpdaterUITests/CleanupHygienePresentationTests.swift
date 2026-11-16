import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

/// The PATH section (D9) and the Files and Folders section (D10), which follows the live Settings
/// switch rather than whatever map the stored report holds.
@MainActor
final class CleanupHygienePresentationTests: XCTestCase {
    private typealias Fixture = CleanupHygienePresentationFixtures
    private typealias Section = CleanupPresentation.Section

    func testPathSectionSitsBetweenShellStateAndTheMap() throws {
        let plain = Fixture.report(findings: [])
        let withSkipped = Fixture.report(findings: [], skippedProtected: ["/Users/cleanup-test/Documents/bin"])

        try withLanguage(.pl) {
            XCTAssertEqual(
                CleanupPresentation.sections(plain, home: Fixture.home).map(\.kind),
                [.duplicates, .homebrew, .runtimes, .gradle, .jetBrains, .shellState, .pathHygiene, .filesAndFolders]
            )
            let sections = CleanupPresentation.sections(withSkipped, home: Fixture.home)
            XCTAssertEqual(
                sections.map(\.kind),
                [.duplicates, .homebrew, .runtimes, .gradle, .jetBrains, .shellState, .pathHygiene, .protectedLocations, .filesAndFolders]
            )
            let path = try section(.pathHygiene, in: sections)
            XCTAssertEqual(path.title, "PATH")
            XCTAssertEqual(path.rows, [])
            XCTAssertEqual(path.notes, [tr("Wpisy PATH są w porządku.")], "a shell read with nothing wrong says so")
        }
    }

    func testApproximatePathAsksForAShellRead() throws {
        let report = Fixture.report(findings: [], path: Fixture.approximatePath)

        try withLanguage(.pl) {
            let path = try section(.pathHygiene, in: CleanupPresentation.sections(report, home: Fixture.home))
            XCTAssertEqual(path.rows, [])
            XCTAssertEqual(path.notes.count, 1)
            let note = try XCTUnwrap(path.notes.first)
            XCTAssertTrue(note.contains(tr("Odczytaj PATH")), note)
            XCTAssertNotEqual(note, tr("Wpisy PATH są w porządku."), "an approximate PATH is not reported as fine")
        }
    }

    func testDeadEntryRowShowsWhereItIsAdded() throws {
        let dead = Fixture.deadPathEntry(locations: [CleanupShellFileLocation(file: "/Users/cleanup-test/.zprofile", line: 3)])
        let report = Fixture.report(findings: [dead])

        try withLanguage(.pl) {
            let path = try section(.pathHygiene, in: CleanupPresentation.sections(report, home: Fixture.home))
            let row = try XCTUnwrap(path.rows.first { $0.findingID == dead.id })
            XCTAssertEqual(row.title, "~/old/bin")
            XCTAssertEqual(row.status, "martwy wpis")
            XCTAssertEqual(row.groupHeader, "PATH")
            XCTAssertNil(row.button, "Wega never edits a shell file")
            let note = try XCTUnwrap(row.note)
            XCTAssertTrue(note.contains("~/.zprofile:3"), note)
            XCTAssertNotEqual(note, tr("tylko informacja"), "an excluded D9 row still shows its advice")
            XCTAssertEqual(path.notes, [], "the all-fine text is not shown above a finding")
        }
    }

    func testDynamicEntrySaysSo() throws {
        let dead = Fixture.deadPathEntry(locations: [])
        let report = Fixture.report(findings: [dead])

        try withLanguage(.pl) {
            let rows = CleanupPresentation.sections(report, home: Fixture.home).flatMap(\.rows)
            let row = try XCTUnwrap(rows.first { $0.findingID == dead.id })
            XCTAssertNil(row.button)
            XCTAssertEqual(row.note, CleanupPresentation.instructionText(.editShellFiles(entry: "~/old/bin", locations: [])))
            XCTAssertTrue(row.note?.contains("eval") == true, row.note ?? "")
        }
    }

    func testMapOffListsWhatMayHaveEntries() throws {
        let report = Fixture.report(findings: [
            Fixture.claudeActive, Fixture.claudeCask, Fixture.claudeNpm, Fixture.gitSystem, Fixture.gitHomebrew,
            Fixture.claudeOldVersion, Fixture.claudeAppManaged,
        ])

        try withLanguage(.pl) {
            let map = try section(.filesAndFolders, in: CleanupPresentation.sections(report, home: Fixture.home))
            XCTAssertEqual(map.rows.map(\.title), ["claude", "~/Library/Application Support/Claude/claude-code"])
            XCTAssertEqual(map.rows.map(\.findingID), [nil, nil], "presentation only: no finding stands behind these rows")
            XCTAssertEqual(map.rows.map(\.bucket), [nil, nil])
            XCTAssertEqual(map.rows.map(\.button), [nil, nil])
            let tool = try XCTUnwrap(map.rows.first)
            XCTAssertTrue(tool.detail.contains("3"), tool.detail)
            XCTAssertTrue(map.notes.contains(Fixture.mapOffNote), "\(map.notes)")
            XCTAssertFalse(map.notes.contains { $0.contains("npm") }, "no Full Disk Access reminder while the map is off")
        }
    }

    func testMapOnButNotScannedAsksForAScan() throws {
        let report = Fixture.report(findings: [Fixture.claudeActive, Fixture.claudeCask, Fixture.claudeNpm, Fixture.claudeAppManaged])

        try withLanguage(.pl) {
            let map = try section(
                .filesAndFolders, in: CleanupPresentation.sections(report, home: Fixture.home, tccMapEnabled: true)
            )
            XCTAssertEqual(map.rows, [])
            XCTAssertTrue(map.notes.contains(tr("Mapa jest włączona. Kliknij „Skanuj”, żeby ją odczytać.")), "\(map.notes)")
            XCTAssertFalse(map.notes.contains(Fixture.mapOffNote))
        }
    }

    func testUnreadableMapNamesFullDiskAccess() throws {
        let unreadable = CleanupDetectorNote(detector: .tccMap, kind: .tccUnreadable)
        let report = Fixture.report(findings: [], notes: [unreadable])

        try withLanguage(.pl) {
            let map = try section(
                .filesAndFolders, in: CleanupPresentation.sections(report, home: Fixture.home, tccMapEnabled: true)
            )
            XCTAssertEqual(map.rows, [])
            XCTAssertEqual(map.notes, [CleanupPresentation.noteText(unreadable)])
            XCTAssertTrue(map.notes[0].contains("Pełnego dostępu do dysku"), map.notes[0])
        }
        for kind in [CleanupDetectorNote.Kind.tccUnsupportedSchema, .tccMapEmpty] {
            let note = CleanupDetectorNote(detector: .tccMap, kind: kind)
            let notes = try withLanguage(.pl) {
                try section(
                    .filesAndFolders,
                    in: CleanupPresentation.sections(Fixture.report(findings: [], notes: [note]), home: Fixture.home, tccMapEnabled: true)
                ).notes
            }
            XCTAssertEqual(notes, [withLanguage(.pl) { CleanupPresentation.noteText(note) }], "\(kind)")
        }
    }

    func testMapRowsReminderAndCommands() throws {
        let report = Fixture.report(findings: [Fixture.claudeActive, Fixture.itermBundle, Fixture.goneEntry])

        try withLanguage(.pl) {
            let map = try section(
                .filesAndFolders, in: CleanupPresentation.sections(report, home: Fixture.home, tccMapEnabled: true)
            )
            XCTAssertEqual(map.rows.compactMap(\.findingID), [Fixture.itermBundle.id, Fixture.goneEntry.id])

            let bundle = try XCTUnwrap(map.rows.first { $0.findingID == Fixture.itermBundle.id })
            XCTAssertEqual(bundle.title, "com.googlecode.iterm2")
            XCTAssertEqual(bundle.button, .copyCommand(Fixture.itermCommand))
            XCTAssertEqual(bundle.note, Fixture.itermCommand)
            XCTAssertEqual(bundle.bucket, .excluded)

            let gone = try XCTUnwrap(map.rows.first { $0.findingID == Fixture.goneEntry.id })
            XCTAssertEqual(gone.title, "~/.local/share/claude/versions/2.1.300/claude")
            XCTAssertEqual(gone.status, "martwy wpis")
            XCTAssertNil(gone.button)
            XCTAssertEqual(gone.note, CleanupPresentation.instructionText(.switchOffInFilesAndFolders))

            let reminder = try XCTUnwrap(map.notes.first { $0.contains("npm") }, "\(map.notes)")
            for program in ["brew", "npm", "mas", "PATH"] {
                XCTAssertTrue(reminder.contains(program), "the reminder names \(program): \(reminder)")
            }
            XCTAssertTrue(reminder.contains("usuń Wegę"), "the reminder says to remove Wega afterwards: \(reminder)")
            XCTAssertFalse(map.notes.contains { $0.contains("tylko") && $0.contains("TCC.db") }, "never \"only to read TCC.db\"")
            XCTAssertEqual(map.notes.count, 2, "the reminder and that Full Disk Access entries are not mapped")
            XCTAssertFalse(map.notes.contains(Fixture.mapOffNote))
        }
        let english = try withLanguage(.en) {
            try section(.filesAndFolders, in: CleanupPresentation.sections(report, home: Fixture.home, tccMapEnabled: true)).notes
        }
        XCTAssertEqual(english.count, 2)
        XCTAssertTrue(english.allSatisfy { $0.contains("Full Disk Access") }, "\(english)")
    }

    func testLinkedServicesShowOnD1D3AndAppManagedRows() throws {
        let linked = [Fixture.claudeActive, Fixture.claudeOldVersion, Fixture.claudeAppManaged]
        let report = Fixture.report(findings: linked + [
            Fixture.mapEntry("/Users/cleanup-test/.local/bin/claude", grants: [.documents, .downloads], linkedTo: Fixture.claudeActive, .activeCopy),
            Fixture.mapEntry(
                "/Users/cleanup-test/.local/share/claude/versions/2.1.322/claude", grants: [.desktop],
                linkedTo: Fixture.claudeOldVersion, .copyToRemove
            ),
            Fixture.mapEntry(
                "/Users/cleanup-test/Library/Application Support/Claude/claude-code/claude", grants: [.documents],
                linkedTo: Fixture.claudeAppManaged, .appManaged(owner: "Claude")
            ),
        ])

        try withLanguage(.pl) {
            let rows = CleanupPresentation.sections(report, home: Fixture.home, tccMapEnabled: true).flatMap(\.rows)
            func detail(_ finding: CleanupFinding) throws -> String {
                try XCTUnwrap(rows.first { $0.findingID == finding.id }, finding.path.path).detail
            }
            XCTAssertTrue(try detail(Fixture.claudeActive).hasSuffix(trf("wpisy w „Pliki i foldery”: %@", "Dokumenty, Pobrane")))
            XCTAssertTrue(try detail(Fixture.claudeOldVersion).hasSuffix(trf("wpisy w „Pliki i foldery”: %@", "Pulpit")))
            XCTAssertTrue(try detail(Fixture.claudeAppManaged).hasSuffix(trf("wpisy w „Pliki i foldery”: %@", "Dokumenty")))

            let off = CleanupPresentation.sections(report, home: Fixture.home).flatMap(\.rows)
            for finding in linked {
                let row = try XCTUnwrap(off.first { $0.findingID == finding.id })
                XCTAssertFalse(row.detail.contains("„Pliki i foldery”"), "no stored map shows while the switch is off: \(row.detail)")
            }
        }
    }

    func testSwitchOffHidesAStoredMap() throws {
        let protectedEntry = Fixture.protectedMapEntry
        let mapFindings = [
            Fixture.itermBundle, Fixture.goneEntry, protectedEntry,
            Fixture.mapEntry("/Users/cleanup-test/.local/bin/claude", grants: [.documents], linkedTo: Fixture.claudeActive, .activeCopy),
        ]
        let report = Fixture.report(
            findings: [Fixture.claudeActive, Fixture.claudeCask] + mapFindings,
            notes: [CleanupDetectorNote(detector: .tccMap, kind: .tccMapEmpty)]
        )

        try withLanguage(.pl) {
            let sections = CleanupPresentation.sections(report, home: Fixture.home, tccMapEnabled: false)
            let shownIDs = Set(sections.flatMap(\.rows).compactMap(\.findingID))
            XCTAssertTrue(shownIDs.isDisjoint(with: mapFindings.map(\.id)), "no D10 row anywhere: \(shownIDs)")
            XCTAssertFalse(sections.contains { $0.kind == .protectedLocations }, "a protected map entry is part of the map")
            let map = try section(.filesAndFolders, in: sections)
            XCTAssertTrue(map.notes.contains(Fixture.mapOffNote), "\(map.notes)")
            XCTAssertFalse(map.notes.contains(CleanupPresentation.noteText(CleanupDetectorNote(detector: .tccMap, kind: .tccMapEmpty))))
            XCTAssertEqual(map.rows.map(\.title), ["claude"], "the switch-off list, built from the copies")
        }
    }

    func testCancelledPathReadShowsNoMessage() {
        withLanguage(.pl) {
            XCTAssertNil(CleanupPresentation.pathReadMessage(.cancelled), "a stopped read is not an error")
            XCTAssertNil(CleanupPresentation.pathReadMessage(nil))
            XCTAssertNotNil(CleanupPresentation.pathReadMessage(.failed), "positive control")
        }
    }

    // MARK: - Helpers

    private func section(_ kind: Section.Kind, in sections: [Section]) throws -> Section {
        try XCTUnwrap(sections.first { $0.kind == kind }, "\(kind)")
    }

    private func withLanguage<T>(_ language: AppLanguage, _ body: () throws -> T) rethrows -> T {
        let previous = LocalizedStrings.current
        LocalizedStrings.current = language
        defer { LocalizedStrings.current = previous }
        return try body()
    }
}

private enum CleanupHygienePresentationFixtures {
    static let home = URL(filePath: "/Users/cleanup-test", directoryHint: .isDirectory)
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let tccDatabase = "/Users/cleanup-test/Library/Application Support/com.apple.TCC/TCC.db"
    static let itermCommand = "tccutil reset SystemPolicyDesktopFolder com.googlecode.iterm2"

    static var mapOffNote: String {
        tr("Mapa, która przypisuje te wpisy do konkretnych kopii, jest wyłączona. Włącz ją w Ustawieniach.")
    }

    static let shellPath = CleanupPathSnapshot(
        entries: ["/Users/cleanup-test/.local/bin", "/opt/homebrew/bin", "/usr/bin"], ignoredEntries: [],
        shell: "zsh", capturedAt: now, isApproximate: false
    )
    static let approximatePath = CleanupPathSnapshot(
        entries: ["/usr/bin", "/bin"], ignoredEntries: [], shell: nil, capturedAt: nil, isApproximate: true
    )

    static let claudeActive = CleanupFinding(
        .pathDuplicates, tool: "claude", path: "/Users/cleanup-test/.local/bin/claude",
        source: .nativeVersionDirectory(tool: "claude"), status: .active, reason: .currentVersion,
        action: .none, bucket: .excluded, version: "2.1.325"
    )
    static let claudeCask = CleanupFinding(
        .pathDuplicates, tool: "claude", path: "/opt/homebrew/bin/claude", source: .homebrewCask(token: "claude-code"),
        status: .shadowed, reason: .shadowedBy(path: "/Users/cleanup-test/.local/bin/claude"),
        action: .brew(.uninstallCask("claude-code")), bucket: .safe, version: "2.1.311"
    )
    static let claudeNpm = CleanupFinding(
        .pathDuplicates, tool: "claude", path: "/usr/local/bin/claude", source: .packageManager(.npm),
        status: .shadowed, reason: .shadowedBy(path: "/Users/cleanup-test/.local/bin/claude"),
        action: .command("npm uninstall -g @anthropic-ai/claude-code"), bucket: .needsDecision, version: "2.1.300"
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
        action: .trash([url("/Users/cleanup-test/.local/share/claude/versions/2.1.322")]), bucket: .safe, version: "2.1.322"
    )
    static let claudeAppManaged = CleanupFinding(
        .versionDirectories, tool: "Claude", path: "/Users/cleanup-test/Library/Application Support/Claude/claude-code",
        source: .appManaged(owner: "Claude"), status: .appManaged, reason: .managedByApp(owner: "Claude"),
        action: .none, bucket: .excluded
    )

    static let itermBundle = CleanupFinding(
        .tccMap, tool: "com.googlecode.iterm2", path: tccDatabase, source: .appBundle(name: "com.googlecode.iterm2"),
        status: .info, reason: .tccEntry(grants: [CleanupTCCGrant(service: .desktop, allowed: true)], link: nil),
        action: .command(itermCommand), bucket: .excluded
    )
    static let goneEntry = CleanupFinding(
        .tccMap, tool: "claude", path: "/Users/cleanup-test/.local/share/claude/versions/2.1.300/claude", source: nil,
        status: .deadEntry, reason: .tccEntryFileGone(grants: [CleanupTCCGrant(service: .documents, allowed: true)]),
        action: .instruction(.switchOffInFilesAndFolders), bucket: .excluded
    )
    static let protectedMapEntry = CleanupFinding(
        .tccMap, tool: "tool", path: "/Users/cleanup-test/Documents/bin/tool", source: nil,
        status: .skippedProtected, reason: .protectedLocation, action: .none, bucket: .excluded
    )

    static func mapEntry(
        _ path: String, grants services: [CleanupTCCService], linkedTo finding: CleanupFinding, _ kind: CleanupTCCLinkKind
    ) -> CleanupFinding {
        CleanupFinding(
            .tccMap, tool: "claude", path: path, source: nil, status: .info,
            reason: .tccEntry(
                grants: services.map { CleanupTCCGrant(service: $0, allowed: $0 != .downloads) },
                link: CleanupTCCLink(findingID: finding.id, kind: kind)
            ),
            action: kind == .copyToRemove ? .instruction(.switchOffInFilesAndFolders) : .none, bucket: .excluded
        )
    }

    static func deadPathEntry(locations: [CleanupShellFileLocation]) -> CleanupFinding {
        CleanupFinding(
            .pathHygiene, tool: "PATH", path: "/Users/cleanup-test/old/bin", source: nil, status: .deadEntry,
            reason: .missingPathEntry,
            action: .instruction(.editShellFiles(entry: "/Users/cleanup-test/old/bin", locations: locations)), bucket: .excluded
        )
    }

    static func url(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .notDirectory)
    }

    static func report(
        findings: [CleanupFinding], notes: [CleanupDetectorNote] = [], skippedProtected: [String] = [],
        path: CleanupPathSnapshot = shellPath
    ) -> CleanupReport {
        CleanupReport(createdAt: now, path: path, findings: findings, notes: notes, skippedProtected: skippedProtected)
    }
}

private extension CleanupFinding {
    /// A finding whose real path is its path; the identity is a fixed value, never read here.
    init(
        _ detector: CleanupDetectorID, tool: String, path: String, source: CleanupSource?,
        status: CleanupStatus, reason: CleanupReason, action: CleanupAction, bucket: CleanupBucket, version: String? = nil
    ) {
        let url = CleanupHygienePresentationFixtures.url(path)
        self.init(
            detector: detector, tool: tool, path: url, realpath: url, source: source,
            version: version, size: nil, status: status, reason: reason, action: action, risk: .low,
            bucket: bucket, identity: CleanupFileIdentity(device: 1, inode: 42)
        )
    }
}
