import Foundation
import MacUpdaterCore

/// What the Cleanup ("Porządki") destination shows: the report as sections and rows, every status,
/// reason and instruction in the active language, the confirmation sheet's content and state, and
/// the exports. Pure: it reads neither the store nor the disk, so the views only bind these values
/// and send the store's intents.
enum CleanupPresentation {
    /// The one control a row offers. A removal opens the confirmation sheet; a command is only
    /// ever copied to the pasteboard, never run.
    enum ButtonKind: Equatable {
        case trash
        case brew
        case brewCleanup
        case copyCommand(String)
        /// Opens "Odinstaluj aplikacje" with the app preselected; nothing is removed here.
        case uninstallApp(name: String, bundle: URL)
    }

    struct Row: Equatable {
        /// The id of the finding the row stands for; nil for a protected location the scan skipped.
        let findingID: String?
        /// The tool's name, on the first of its rows in the duplicates section.
        let groupHeader: String?
        /// The finding's bucket, which the status badge is coloured by; nil for a skipped location.
        let bucket: CleanupBucket?
        let status: String
        /// The item's path, with `~` for the home directory.
        let title: String
        let detail: String
        let sizeText: String?
        let button: ButtonKind?
        /// Shown beside the button or instead of it: the command to copy, the instruction to
        /// follow, or that the row is for information only.
        let note: String?
        /// The "keep this copy" radio of a copy that offers the choice; nil for every other row.
        var keep: KeepControl? = nil
        /// True when the row offers a button, advice to follow, or a "zostaw" choice still to make.
        var isActionable = false
        /// Where a copy on `PATH` comes from; nil outside the duplicates section.
        var origin: Origin? = nil

        /// The source and directory of a copy, which tools installed in one place share.
        struct Origin: Equatable {
            let source: String
            let directory: String
        }

        func appendingDetail(_ text: String) -> Row {
            Row(
                findingID: findingID, groupHeader: groupHeader, bucket: bucket, status: status, title: title,
                detail: detail + " · " + text, sizeText: sizeText, button: button, note: note, keep: keep,
                isActionable: isActionable, origin: origin
            )
        }
    }

    struct Section: Equatable {
        enum Kind: Hashable {
            case duplicates, homebrew, runtimes, gradle, jetBrains, shellState, pathHygiene, protectedLocations, filesAndFolders
        }

        let kind: Kind
        let title: String
        /// Paragraphs under the title: detector failures, an approximate `PATH`, or an explanation.
        let notes: [String]
        let rows: [Row]
    }

    /// Everything the confirmation sheet states before a removal.
    struct Confirmation: Equatable {
        let paths: [String]
        let sizeText: String
        let reason: String
        let action: String
        let risk: String
        /// Whether the confirmed action can be undone; nil when the action removes nothing.
        let effect: String?
        /// The processes that used the item during the scan, arguments included. Shown live only.
        let processes: [String]
        let confirmTitle: String
        /// For the copy `PATH` uses now: which copy Terminal uses once it is gone.
        let takeover: String?
    }

    /// Where the confirmation sheet's own removal request stands.
    enum SheetState: Equatable {
        /// Nothing sent yet; an outcome on the store belongs to an earlier request.
        case ready
        case working
        /// The remover found these processes using the item; a second confirmation is needed.
        case needsAcknowledgement([CleanupProcess])
        case refused(String)
        case done
    }

    enum ExportFormat {
        case text, json

        var fileName: String {
            switch self {
            case .text: tr("raport-porządków") + ".txt"
            case .json: tr("raport-porządków") + ".json"
            }
        }

        /// While `tccMapEnabled` is off, the export leaves out any map the report still holds.
        func data(_ report: CleanupReport, home: URL, tccMapEnabled: Bool) throws -> Data {
            let report = tccMapEnabled ? report : CleanupPresentation.withoutMap(report)
            switch self {
            case .text: return Data(CleanupPresentation.exportText(report, home: home).utf8)
            case .json: return try CleanupReportRenderer.json(report, home: home)
            }
        }
    }

    /// A shell read older than this is offered for a refresh.
    static let pathRefreshInterval: TimeInterval = 7 * 86_400

    // MARK: - Sections

    /// The sections in the sidebar sketch's order: copies of one tool, Homebrew leftovers, version
    /// managers, Gradle, JetBrains, shell state, `PATH` hygiene, skipped protected locations (only
    /// when there are some) and the "Files and Folders" map. Each detector's findings and notes go
    /// to its own section, and every section but the shell state groups its rows by tool.
    ///
    /// The map follows `tccMapEnabled`, the live Settings switch, not the stored report: while the
    /// switch is off, a map the report still holds shows nowhere, not even as a protected location.
    static func sections(_ report: CleanupReport, home: URL, tccMapEnabled: Bool = false) -> [Section] {
        let map = mapState(of: report, tccMapEnabled: tccMapEnabled)
        let report = map == .off ? withoutMap(report) : report
        let isProtected: (CleanupFinding) -> Bool = { $0.status == .skippedProtected }
        let listed = report.findings.filter { !isProtected($0) }
        let findings = { (kind: Section.Kind) in listed.filter { sectionKind(of: $0.detector) == kind } }
        let notes = { (kind: Section.Kind) in report.notes.filter { sectionKinds(of: $0).contains(kind) }.map(noteText) }
        let grouped = { (kind: Section.Kind, title: String, extraNotes: [String], empty: String) in
            section(kind, title, notes: notes(kind) + extraNotes, rows: groupedRows(findings(kind), home: home), empty: empty)
        }
        var approximatePathNotes: [String] = []
        if report.path.isApproximate, listed.contains(where: { $0.detector == .pathDuplicates }) {
            approximatePathNotes.append(trf(
                "PATH jest %@, więc to, która kopia jest aktywna, może się różnić od Terminala. Odczytaj PATH z powłoki, żeby to potwierdzić.",
                tr("przybliżony")
            ))
        }

        var sections = [
            grouped(.duplicates, tr("Wiele kopii tego samego narzędzia"), approximatePathNotes, tr("Nie znaleziono kopii ani starych wersji narzędzi.")),
            grouped(.homebrew, tr("Homebrew"), [], tr("Homebrew nie ma nic do sprzątnięcia.")),
            grouped(.runtimes, tr("Menedżery wersji"), [], tr("Nie znaleziono nieużywanych wersji.")),
            grouped(.gradle, tr("Gradle"), [], tr("Nie znaleziono nieużywanych dystrybucji ani JDK.")),
            grouped(.jetBrains, tr("JetBrains"), [], tr("Nie znaleziono katalogów starych wersji IDE.")),
            section(.shellState, tr("Stan powłok"), notes: notes(.shellState),
                    rows: findings(.shellState).map { row(for: $0, home: home, groupHeader: nil, namesTool: true) },
                    empty: tr("Nie znaleziono pozostałości po sesjach powłoki.")),
            report.path.isApproximate
                ? Section(kind: .pathHygiene, title: tr("PATH"), notes: [
                    tr("PATH jest przybliżony, więc Wega nie sprawdza jego wpisów. Kliknij „Odczytaj PATH”, a potem „Skanuj”."),
                ] + notes(.pathHygiene), rows: [])
                : grouped(.pathHygiene, tr("PATH"), [], tr("Wpisy PATH są w porządku.")),
        ]
        let skipped = report.skippedProtected.map { skippedRow($0, home: home) }
            + report.findings.filter(isProtected).map { row(for: $0, home: home, groupHeader: nil, namesTool: true) }
        if !skipped.isEmpty {
            sections.append(Section(kind: .protectedLocations, title: tr("Pominięte lokalizacje chronione"), notes: [], rows: skipped))
        }
        sections.append(filesAndFoldersSection(
            map, notes: notes(.filesAndFolders),
            rows: groupedRows(findings(.filesAndFolders), home: home, linkKeeps: linkKeeps(in: report)),
            offRows: mayHaveEntriesRows(listed, home: home)
        ))
        return map == .read ? addingLinkedEntries(to: sections, from: report.findings) : sections
    }

    private static func section(_ kind: Section.Kind, _ title: String, notes: [String], rows: [Row], empty: String) -> Section {
        Section(kind: kind, title: title, notes: rows.isEmpty && notes.isEmpty ? [empty] : notes, rows: rows)
    }

    /// The section a detector's findings are listed in.
    private static func sectionKind(of detector: CleanupDetectorID) -> Section.Kind {
        switch detector {
        case .pathDuplicates, .source, .versionDirectories: .duplicates
        case .homebrew: .homebrew
        case .runtimeVersions: .runtimes
        case .gradle: .gradle
        case .jetBrains: .jetBrains
        case .shellState: .shellState
        case .pathHygiene: .pathHygiene
        case .tccMap: .filesAndFolders
        }
    }

    /// The sections a detector note is shown in. Homebrew's dependency-check notes concern the
    /// copies; only its failed leftovers query belongs to the Homebrew section. Gradle reads the
    /// same project walk as the version managers, so it repeats why the walk may have missed one.
    private static func sectionKinds(of note: CleanupDetectorNote) -> [Section.Kind] {
        switch (note.detector, note.kind) {
        case (.homebrew, .dryRunFailed): [.homebrew]
        case (.homebrew, _): [.duplicates]
        case (.runtimeVersions, .noProjectRoots), (.runtimeVersions, .projectWalkTruncated): [.runtimes, .gradle]
        case (let detector, _): [sectionKind(of: detector)]
        }
    }

    /// Rows of one tool stay together, tools in the order the report first names them. The match
    /// ignores case, so an app-managed copy owned by "Claude" joins the `claude` tool's rows.
    /// `linkKeeps` holds the keep state of each D1 candidate by finding id, which a Files and
    /// Folders entry linked to that copy is labelled by.
    private static func groupedRows(
        _ findings: [CleanupFinding], home: URL, linkKeeps: [String: CleanupKeep] = [:]
    ) -> [Row] {
        var order: [String] = []
        var groups: [String: [CleanupFinding]] = [:]
        for finding in findings {
            let key = finding.tool.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(finding)
        }
        return order.flatMap { key -> [Row] in
            let members = groups[key] ?? []
            let sorted = members.enumerated()
                .sorted { (rank($0.element.status), $0.offset) < (rank($1.element.status), $1.offset) }
                .map(\.element)
            return sorted.enumerated().map { index, finding in
                row(
                    for: finding, home: home, groupHeader: index == 0 ? members.first?.tool : nil, namesTool: false,
                    linkKeeps: linkKeeps
                )
            }
        }
    }

    /// The active copy first, then what may go, then what stays.
    private static func rank(_ status: CleanupStatus) -> Int {
        switch status {
        case .active: 0
        case .shadowed, .unused, .stale, .inUse: 1
        case .deadEntry: 1
        case .dependency, .brokenLink, .pinned, .recentUpgrade: 2
        case .expected, .appManaged, .info, .skippedProtected: 3
        }
    }

    private static func row(
        for finding: CleanupFinding, home: URL, groupHeader: String?, namesTool: Bool,
        linkKeeps: [String: CleanupKeep] = [:]
    ) -> Row {
        let control = control(for: finding, home: home)
        let keep = keepControl(of: finding)
        let title = isMapBundleEntry(finding) ? finding.tool : tilde(finding.path.path, home)
        return Row(
            findingID: finding.id, groupHeader: groupHeader, bucket: finding.bucket, status: statusText(finding.status),
            title: title,
            detail: detail(of: finding, home: home, namesTool: namesTool, linkKeeps: linkKeeps),
            sizeText: finding.size.map(sizeText), button: control.button, note: control.note,
            keep: keep,
            isActionable: control.isActionable,
            origin: origin(of: finding, title: title)
        )
    }

    private static func origin(of finding: CleanupFinding, title: String) -> Row.Origin? {
        guard finding.detector == .pathDuplicates, let source = finding.source else { return nil }
        return Row.Origin(source: sourceText(source), directory: (title as NSString).deletingLastPathComponent)
    }

    /// What a row offers: its button, its note, and whether either asks the user to act.
    private struct Control {
        let button: ButtonKind?
        let note: String?
        let isActionable: Bool

        static func offer(_ button: ButtonKind, note: String? = nil) -> Control {
            Control(button: button, note: note, isActionable: true)
        }

        static func advice(_ note: String) -> Control {
            Control(button: nil, note: note, isActionable: true)
        }

        static func keepChoice(_ note: String, undecided: Bool) -> Control {
            Control(button: nil, note: note, isActionable: undecided)
        }

        static var informationOnly: Control { Control(button: nil, note: tr("tylko informacja"), isActionable: false) }
    }

    /// The button comes from the finding's action alone; an excluded finding never offers one to
    /// remove. A JetBrains folder of a version an installed IDE replaced also names the IDE's own
    /// cleanup, which knows its folders best; it does not clear a folder no installed IDE explains.
    private static func control(for finding: CleanupFinding, home: URL) -> Control {
        if let note = keepNote(for: finding) {
            return .keepChoice(note, undecided: keepControl(of: finding) == .undecided)
        }
        guard finding.bucket != .excluded else { return excludedControl(for: finding, home: home) }
        switch finding.action {
        case .trash, .trashBatch:
            guard finding.detector == .jetBrains, case .ideVersionNotInstalled = finding.reason else {
                return .offer(.trash)
            }
            let advice = tr("Zalecane: w IDE wybierz Help → Delete Leftover IDE Directories. Wega może też przenieść ten katalog do Kosza.")
            return .offer(.trash, note: advice)
        case .brew(.cleanup): return .offer(.brewCleanup)
        case .brew: return .offer(.brew)
        case .command(let command): return .offer(.copyCommand(command), note: command)
        case .instruction(let instruction): return .advice(instructionNote(for: finding, instruction, home: home))
        case .uninstallApp(let name, let bundle): return .offer(.uninstallApp(name: name, bundle: bundle))
        case .none: return .informationOnly
        }
    }

    /// `PATH` hygiene, the Files and Folders map and a broken link on `PATH` are advice only, so
    /// their excluded rows still show the instruction to follow or the command to copy; Wega runs
    /// neither.
    private static func excludedControl(for finding: CleanupFinding, home: URL) -> Control {
        guard finding.detector == .pathHygiene || finding.detector == .tccMap || isBrokenLinkOnPath(finding) else {
            return .informationOnly
        }
        switch finding.action {
        case .instruction(let instruction): return .advice(instructionNote(for: finding, instruction, home: home))
        case .command(let command): return .offer(.copyCommand(command), note: command)
        case .trash, .trashBatch, .brew, .uninstallApp, .none: return .informationOnly
        }
    }

    private static func detail(
        of finding: CleanupFinding, home: URL, namesTool: Bool, linkKeeps: [String: CleanupKeep]
    ) -> String {
        var parts: [String] = namesTool ? [finding.tool] : []
        if let source = finding.source, !isMapBundleEntry(finding) { parts.append(sourceText(source)) }
        if let version = finding.version {
            parts.append(version)
        } else if finding.source == .standalone, finding.status != .brokenLink {
            parts.append(tr("wersja nieznana"))
        }
        parts.append(
            linkedEntryText(finding.reason, linkKeeps: linkKeeps)
                ?? reasonText(displayed(finding.reason, home: home), requiredBy: pinnedPaths(in: finding.status, home: home))
        )
        let users = processes(of: finding)
        if !users.isEmpty {
            parts.append(trf("używa: %@", users.map(processName).joined(separator: ", ")))
        }
        return parts.joined(separator: " · ")
    }

    private static func skippedRow(_ path: String, home: URL) -> Row {
        Row(
            findingID: nil, groupHeader: nil, bucket: nil, status: statusText(.skippedProtected), title: tilde(path, home),
            detail: reasonText(.protectedLocation), sizeText: nil, button: nil, note: nil
        )
    }

    // MARK: - Header

    static func headline(_ totals: CleanupTotals) -> String {
        trf("Do odzyskania: %@ bezpiecznie · %@ wymaga decyzji", sizeText(totals.safe), sizeText(totals.needsDecision))
    }

    /// Where `PATH` comes from: the badge text for an approximation, otherwise the shell and the
    /// capture date, with a refresh suggestion once the read is older than seven days.
    static func pathHint(_ snapshot: CleanupPathSnapshot?, now: Date) -> String {
        guard let snapshot, !snapshot.isApproximate else { return tr("przybliżony") }
        let shell = snapshot.shell ?? "?"
        guard let capturedAt = snapshot.capturedAt else { return trf("z powłoki %@, %@", shell, "—") }
        let hint = trf("z powłoki %@, %@", shell, dateText(capturedAt))
        guard now.timeIntervalSince(capturedAt) > pathRefreshInterval else { return hint }
        return hint + " · " + tr("Odczyt ma ponad 7 dni — odczytaj PATH ponownie.")
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func scanDateText(_ date: Date) -> String {
        trf("Wynik skanu z %@", dateText(date))
    }

    static func progressText(_ phase: CleanupStore.Phase) -> String? {
        switch phase {
        case .idle: nil
        case .readingPath: tr("Odczytuję PATH z powłoki…")
        case .scanning: tr("Skanuję…")
        case .removing: tr("Usuwam…")
        }
    }

    /// What Wega says when a scan ends. A stopped scan is not announced as done: the report on
    /// screen is still the previous one.
    static func scanEndedState(failed: Bool, cancelled: Bool) -> WegaState {
        if failed { return WegaState(pose: .sad, line: tr("Skan się nie udał.")) }
        if cancelled { return WegaState(pose: .idle, line: tr("Skan przerwany — poprzedni raport zostaje.")) }
        return WegaState(pose: .happy, line: tr("Gotowe. Zobacz, co mogę posprzątać."))
    }

    static func pathReadMessage(_ result: CleanupPathReadResult?) -> String? {
        switch result {
        case nil, .captured, .cancelled: nil
        case .unsupportedShell(let shell):
            trf("Powłoka %@ nie jest obsługiwana, więc PATH nie został odczytany. Skan użyje poprzedniego odczytu albo przybliżonego PATH.", shell)
        case .failed:
            tr("Nie udało się odczytać PATH z powłoki. Skan użyje poprzedniego odczytu albo przybliżonego PATH.")
        }
    }

    static func buttonTitle(_ kind: ButtonKind) -> String {
        switch kind {
        case .trash: tr("Do Kosza…")
        case .brew: tr("Odinstaluj…")
        case .brewCleanup: tr("Posprzątaj…")
        case .copyCommand: tr("Kopiuj polecenie")
        case .uninstallApp(let name, _): trf("Odinstaluj %@…", name)
        }
    }

    // MARK: - Texts

    static func statusText(_ status: CleanupStatus) -> String {
        switch status {
        case .active: tr("aktywna")
        case .shadowed: tr("przesłonięta")
        case .unused: tr("nieużywana")
        case .stale: tr("nieaktualny")
        case .inUse: tr("w użyciu")
        case .expected: tr("oczekiwana")
        case .appManaged: tr("zarządzana przez aplikację")
        case .dependency: tr("zależność")
        case .brokenLink: tr("uszkodzone dowiązanie")
        case .skippedProtected: tr("pominięta (lokalizacja chroniona)")
        case .pinned: tr("potrzebna")
        case .recentUpgrade: tr("świeżo zaktualizowana")
        case .info: tr("informacja")
        case .deadEntry: tr("martwy wpis")
        }
    }

    /// Paths inside a reason are shown as given; callers pass them with `~` already substituted.
    static func reasonText(_ reason: CleanupReason) -> String {
        reasonText(reason, requiredBy: [])
    }

    /// `requiredBy` holds the paths of a `.pinned` status, which the reason `.requiredByProjects`
    /// names; the plain-text export lists them in a field of their own.
    private static func reasonText(_ reason: CleanupReason, requiredBy paths: [String]) -> String {
        switch reason {
        case .olderVersion(let current): trf("starsza wersja; bieżąca to %@", current)
        case .newerVersion(let current): trf("nowsza wersja; bieżąca to %@", current)
        case .shadowedBy(let path): trf("przesłania ją %@, wcześniej w PATH", path)
        case .systemCopy: tr("kopia dostarczana z macOS")
        case .managedByApp(let owner): trf("aktualizuje ją aplikacja %@", owner)
        case .staleSinceBoot(let count): trf("wpisy sprzed ostatniego uruchomienia systemu: %@", "\(count)")
        case .keptSinceBoot(let count): trf("wpisy z bieżącego uruchomienia, zostają: %@", "\(count)")
        case .unknownVersionDirectory: tr("katalog wersji, którego układu Wega nie zna")
        case .currentVersion: tr("bieżąca wersja")
        case .protectedLocation: tr("lokalizacja chroniona — Wega jej nie odczytuje")
        case .brokenLink: tr("dowiązanie wskazuje nieistniejący plik")
        case .requiredBy(let dependents): trf("potrzebna formułom: %@", dependents.joined(separator: ", "))
        case .homebrewLeftovers(let items):
            trf("stare wersje i pobrane pliki do usunięcia przez brew cleanup: %@", "\(items)")
        case .homebrewKeptVersions(let count):
            trf("Homebrew zostawia kilka wersji (%@) — przypięta formuła albo cask, który aktualizuje się sam", "\(count)")
        case .installedOnlyAsDependency: tr("zainstalowana tylko jako zależność; możesz jej jednak używać bezpośrednio")
        case .recentlyUpgraded: tr("zaktualizowana w ostatnich 7 dniach — poprzednie wersje zostają na wypadek przywracania")
        case .notRequiredByProjects: tr("nie wskazuje jej żaden projekt w katalogach projektów ani ustawienie menedżera")
        case .requiredByProjects: trf("wskazuje ją: %@", paths.isEmpty ? "—" : paths.joined(separator: ", "))
        case .unusedGradleDistribution: tr("nie wskazuje jej żaden wrapper Gradle; wrapper pobierze ją ponownie, gdy będzie potrzebna")
        case .unreferencedJDK(let major): trf("żaden projekt nie wymaga Javy %@", "\(major)")
        case .systemJDK(let major): trf("systemowa Java %@", "\(major)")
        case .ideVersionNotInstalled(let installed):
            trf("ta wersja IDE nie jest zainstalowana; zainstalowane: %@", installed.joined(separator: ", "))
        case .ideNotFound: tr("nie znaleziono zainstalowanego IDE tego produktu")
        case .newerThanInstalledIDE(let installed):
            trf("nowsza niż zainstalowane IDE (%@)", installed.joined(separator: ", "))
        case .missingPathEntry, .repeatedPathEntry, .samePlaceAs, .nestedIn, .olderCopyWins, .tccEntry, .tccEntryFileGone,
             .keptInstead, .keptByChoice, .noCopyKept, .versionManagerShim:
            hygieneReasonText(reason, requiredBy: paths)
        }
    }

    /// The `PATH` hygiene, Files and Folders, keep-choice and version-manager shim reasons. The other
    /// reasons are listed rather than defaulted, so a reason added later fails to compile here until
    /// it has a text.
    private static func hygieneReasonText(_ reason: CleanupReason, requiredBy paths: [String]) -> String {
        switch reason {
        case .missingPathEntry: tr("ten katalog nie istnieje albo nie jest katalogiem, więc nic w nim nie szukamy")
        case .repeatedPathEntry(let count): trf("ten sam wpis występuje w PATH %@ razy; liczy się pierwszy", "\(count)")
        case .samePlaceAs(let path): trf("to samo miejsce co wcześniejszy wpis %@", path)
        case .nestedIn(let parent): trf("leży wewnątrz katalogu %@, który też jest w PATH", parent)
        case .olderCopyWins(let version, let newer, let newerVersion):
            trf("aktywna jest wersja %@, a przesłonięta kopia %@ ma nowszą wersję %@", version, newer, newerVersion)
        case .tccEntry(let grants, let link):
            tccEntryText(grants: grants, link: link)
        case .tccEntryFileGone(let grants):
            trf("wpis w „Pliki i foldery” (%@) wskazuje plik, którego już nie ma", grantsText(grants))
        case .keptInstead(let path): trf("zostawiasz %@", path)
        case .keptByChoice: tr("tę kopię zostawiasz")
        case .noCopyKept: tr("nie wybrano kopii do zostawienia")
        case .versionManagerShim: tr("shim: uruchamia wersję, którą wskazuje menedżer")
        case .olderVersion, .newerVersion, .shadowedBy, .systemCopy, .managedByApp, .staleSinceBoot, .keptSinceBoot,
             .unknownVersionDirectory, .currentVersion, .protectedLocation, .brokenLink, .requiredBy, .homebrewLeftovers,
             .homebrewKeptVersions, .installedOnlyAsDependency, .recentlyUpgraded, .notRequiredByProjects, .requiredByProjects,
             .unusedGradleDistribution, .unreferencedJDK, .systemJDK, .ideVersionNotInstalled, .ideNotFound, .newerThanInstalledIDE:
            reasonText(reason, requiredBy: paths)
        }
    }

    /// `label` replaces the stored link kind's text, for an entry of a copy the user chose about.
    static func tccEntryText(grants: [CleanupTCCGrant], link: CleanupTCCLink?, label: String? = nil) -> String {
        let entry = trf("wpis w „Pliki i foldery”: %@", grantsText(grants))
        guard let link else { return entry }
        if let label { return "\(entry); \(label)" }
        let kind = switch link.kind {
        case .activeCopy: tr("dotyczy aktywnej kopii")
        case .copyToRemove: tr("dotyczy kopii do usunięcia")
        case .keptCopy: tr("dotyczy kopii, która zostaje")
        case .appManaged(let owner): trf("dotyczy kopii aplikacji %@", owner)
        }
        return "\(entry); \(kind)"
    }

    private static func grantsText(_ grants: [CleanupTCCGrant]) -> String {
        grants.map { grant in
            trf(grant.allowed ? "%@ (zezwolono)" : "%@ (odmówiono)", serviceName(grant.service))
        }.joined(separator: ", ")
    }

    private static func serviceName(_ service: CleanupTCCService) -> String {
        switch service {
        case .desktop: tr("Pulpit")
        case .documents: tr("Dokumenty")
        case .downloads: tr("Pobrane")
        case .networkVolumes: tr("woluminy sieciowe")
        case .removableVolumes: tr("woluminy wymienne")
        case .allFiles: tr("Pełny dostęp do dysku")
        }
    }

    static func instructionText(_ instruction: CleanupInstruction) -> String {
        switch instruction {
        case .removeWithCreatingTool:
            tr("Usuń ją narzędziem, które ją zainstalowało.")
        case .removeAppLinkWithAdminRights(let link):
            trf("Dowiązanie %@ prowadzi do aplikacji; usuń je ręcznie, z uprawnieniami administratora.", link)
        case .editShellFiles(let entry, let locations):
            removeEntryText(entry, locations: locations)
        case .switchOffInFilesAndFolders:
            tr("Wyłącz ten wpis w Ustawieniach systemowych → Prywatność i ochrona → Pliki i foldery.")
        }
    }

    static func noteText(_ note: CleanupDetectorNote) -> String {
        switch (note.kind, note.detector) {
        case (.homebrewUnavailable, _):
            tr("Homebrew jest niedostępny, więc Wega nie sprawdziła, czy inne formuły zależą od przesłoniętych kopii. Te kopie nie mają akcji usunięcia.")
        case (.failed, .homebrew):
            tr("Sprawdzenie zależności Homebrew nie powiodło się. Formuły, których nie sprawdzono, nie mają akcji usunięcia.")
        case (.dryRunFailed, _):
            tr("Homebrew nie odpowiedział na pytanie o pozostałości. Tej części nie ma w raporcie.")
        case (.noProjectRoots, _):
            tr("Nie przeszukano żadnego katalogu projektów, więc Wega nie wie, których wersji używają projekty. Dodaj katalogi w Ustawieniach.")
        case (.projectWalkTruncated, _):
            tr("Katalogów projektów jest więcej, niż Wega przeszukuje w jednym skanie. Część wersji może być potrzebna projektom, których nie sprawdzono.")
        case (.unrecognisedIDEInstall, _):
            tr("Jedno z IDE JetBrains nie ma pliku product-info.json, więc katalogi tego produktu zostają bez zmian.")
        case (.tccUnreadable, _):
            tr("Wega nie mogła odczytać bazy zgód. Brakuje jej Pełnego dostępu do dysku albo pliku bazy nie ma, więc mapy „Pliki i foldery” nie ma w raporcie.")
        case (.tccUnsupportedSchema, _):
            tr("Baza zgód ma układ, którego Wega nie zna, więc nie zgaduje i mapy „Pliki i foldery” nie ma w raporcie.")
        case (.tccMapEmpty, _):
            tr("Baza zgód nie ma wpisów dla plików i folderów. Pełny dostęp do dysku jest w bazie systemowej, której Wega nie mapuje.")
        case (.failed, let detector):
            trf("Ta część skanu nie powiodła się: %@. Jej wyników nie ma w raporcie.", detectorName(detector))
        }
    }

    private static func detectorName(_ detector: CleanupDetectorID) -> String {
        switch detector {
        case .pathDuplicates: tr("kopie w PATH")
        case .source: tr("źródła kopii")
        case .versionDirectories: tr("katalogi wersji")
        case .homebrew: tr("zależności Homebrew")
        case .shellState: tr("stan powłok")
        case .runtimeVersions: tr("wersje środowisk")
        case .gradle: tr("Gradle")
        case .jetBrains: tr("katalogi IDE JetBrains")
        case .pathHygiene: tr("higiena PATH")
        case .tccMap: tr("mapa „Pliki i foldery”")
        }
    }

    private static func sourceText(_ source: CleanupSource) -> String {
        switch source {
        case .homebrewFormula(let name): trf("formuła Homebrew %@", name)
        case .homebrewCask(let token): trf("cask Homebrew %@", token)
        case .appBundle(let name): trf("z aplikacji %@", name)
        case .appManaged(let owner): trf("kopia aplikacji %@", owner)
        case .versionManager(let manager): trf("menedżer wersji %@", manager.rawValue)
        case .packageManager(let manager): trf("menedżer pakietów %@", manager.rawValue)
        case .nativeVersionDirectory(let tool): trf("własny instalator %@", tool)
        case .system: tr("kopia systemowa")
        case .standalone: tr("samodzielna kopia")
        }
    }

    private static func riskText(_ risk: CleanupRisk) -> String {
        let level = switch risk {
        case .low: tr("niskie")
        case .medium: tr("średnie")
        case .high: tr("wysokie")
        }
        return trf("Ryzyko: %@", level)
    }

    // MARK: - Confirmation

    static func confirmation(for finding: CleanupFinding, home: URL) -> Confirmation {
        Confirmation(
            paths: targetPaths(of: finding, home: home),
            sizeText: finding.size.map(sizeText) ?? tr("nieznany"),
            reason: reasonText(displayed(finding.reason, home: home), requiredBy: pinnedPaths(in: finding.status, home: home)),
            action: actionText(finding.action, home: home),
            risk: riskText(finding.risk),
            effect: effectText(for: finding.action),
            processes: processes(of: finding).map(processLine),
            confirmTitle: confirmTitle(for: finding.action),
            takeover: takeoverText(for: finding, home: home)
        )
    }

    /// Whether the confirmed action can be taken back; nil for an action that removes nothing.
    static func effectText(for action: CleanupAction) -> String? {
        switch action {
        case .trash, .trashBatch: tr("Przeniesie do Kosza — możesz przywrócić, dopóki go nie opróżnisz.")
        case .brew: tr("Uruchomi polecenie Homebrew — Wega tego nie cofnie.")
        case .command: tr("Tylko kopiuje polecenie; nic teraz nie usuwa.")
        case .instruction, .uninstallApp, .none: nil
        }
    }

    private static func confirmTitle(for action: CleanupAction) -> String {
        switch action {
        case .brew(.cleanup): tr("Posprzątaj")
        case .brew: tr("Odinstaluj")
        default: tr("Przenieś do Kosza")
        }
    }

    /// Name, PID and the arguments held in memory. Arguments can carry tokens: this line is for
    /// the sheet only, never for a log or an export.
    static func processLine(_ process: CleanupProcess) -> String {
        let name = processName(process)
        return process.arguments.isEmpty ? name : name + ": " + process.arguments.joined(separator: " ")
    }

    static func sheetState(submitted: Bool, phase: CleanupStore.Phase, outcome: CleanupRemovalOutcome?) -> SheetState {
        guard submitted else { return .ready }
        if case .removing = phase { return .working }
        if outcome == .removed { return .done }
        guard phase == .idle, let outcome else { return .working }
        if case .needsInUseAcknowledgement(let processes) = outcome { return .needsAcknowledgement(processes) }
        return .refused(outcomeMessage(outcome) ?? "")
    }

    static func canConfirm(_ state: SheetState, phase: CleanupStore.Phase, acknowledged: Bool) -> Bool {
        guard phase == .idle else { return false }
        switch state {
        case .ready: return true
        case .needsAcknowledgement: return acknowledged
        case .working, .refused, .done: return false
        }
    }

    /// The first request never acknowledges use; only a request sent while the remover's process
    /// list is on screen can carry the user's acknowledgement.
    static func removalIntent(for finding: CleanupFinding, state: SheetState, acknowledged: Bool) -> CleanupRemovalIntent {
        guard case .needsAcknowledgement = state else {
            return CleanupRemovalIntent(finding: finding, inUseAcknowledged: false)
        }
        return CleanupRemovalIntent(finding: finding, inUseAcknowledged: acknowledged)
    }

    static func outcomeMessage(_ outcome: CleanupRemovalOutcome) -> String? {
        switch outcome {
        case .removed:
            tr("Usunięto. Wega odświeża wynik.")
        case .notRemovable:
            tr("Tego elementu Wega nie usuwa sama — skorzystaj z polecenia lub wskazówki przy nim.")
        case .needsInUseAcknowledgement:
            nil
        case .changedSinceScan:
            tr("Ten element zmienił się od skanu, więc niczego nie ruszono. Kliknij „Skanuj” i spróbuj ponownie.")
        case .nowRequiredBy(let dependents):
            trf("Niczego nie usunięto: tej formuły potrzebują teraz %@.", dependents.joined(separator: ", "))
        case .failed(let error):
            trf("Usunięcie nie powiodło się (%@). Uruchom skan, żeby zobaczyć bieżący stan.", error)
        }
    }

    private static func targetPaths(of finding: CleanupFinding, home: URL) -> [String] {
        switch finding.action {
        case .trash(let urls): urls.map { tilde($0.path, home) }
        case .trashBatch(let parent, _): [tilde(parent.path, home)]
        default: [tilde(finding.path.path, home)]
        }
    }

    /// Homebrew commands are spelled by `CleanupActionText`, as the text export writes them and as
    /// `BrewService` runs them.
    private static func actionText(_ action: CleanupAction, home: URL) -> String {
        switch action {
        case .trash(let urls):
            trf("Przeniesienie do Kosza: %@", urls.map { tilde($0.path, home) }.joined(separator: ", "))
        case .trashBatch(let parent, let entries):
            trf("Przeniesienie do Kosza — liczba wpisów: %@, folder: %@", "\(entries.count)", tilde(parent.path, home))
        case .brew(let brew):
            CleanupActionText.command(for: brew)
        case .command(let command):
            command
        case .uninstallApp(let name, let bundle):
            trf("Odinstaluj aplikację %@ (%@)", name, tilde(bundle.path, home))
        case .instruction(let instruction):
            instructionText(displayed(instruction, home: home))
        case .none:
            tr("tylko informacja")
        }
    }

}

// MARK: - Export

extension CleanupPresentation {
    /// The plain-text export: a header with the totals, the detector notes and the skipped
    /// protected locations, then the renderer's line per finding. No process arguments.
    static func exportText(_ report: CleanupReport, home: URL) -> String {
        var lines = [
            trf("Porządki — raport z %@", dateText(report.createdAt)),
            "PATH: " + pathHint(report.path, now: report.createdAt),
            headline(report.totals),
            "",
        ]
        if report.notes.isEmpty {
            lines.append(tr("Uwagi skanu: brak"))
        } else {
            lines.append(tr("Uwagi skanu:"))
            lines += report.notes.map { "- " + noteText($0) }
        }
        lines.append("")
        if report.skippedProtected.isEmpty {
            lines.append(tr("Pominięte lokalizacje chronione: brak"))
        } else {
            lines.append(tr("Pominięte lokalizacje chronione") + ":")
            lines += report.skippedProtected.map { "- " + tilde($0, home) }
        }
        let keeps = linkKeeps(in: report)
        let findings = CleanupReportRenderer.text(
            report, home: home, reasonText: { linkedEntryText($0, linkKeeps: keeps) ?? reasonText($0) }, statusText: statusText
        )
        return lines.joined(separator: "\n") + "\n\n" + findings
    }

    // MARK: - Helpers

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func tilde(_ path: String, _ home: URL) -> String {
        CleanupReportRenderer.tildePath(path, home: home)
    }

    private static func processName(_ process: CleanupProcess) -> String {
        "\(process.name) (PID \(process.pid))"
    }

    /// The processes the scan saw using the item. A `PATH`-active copy keeps the status `active`
    /// even while in use, so its candidate's own list stands in.
    private static func processes(of finding: CleanupFinding) -> [CleanupProcess] {
        if case .inUse(let processes) = finding.status { return processes }
        return finding.candidate?.processes ?? []
    }

    private static func pinnedPaths(in status: CleanupStatus, home: URL) -> [String] {
        guard case .pinned(let paths) = status else { return [] }
        return paths.map { tilde($0, home) }
    }

    private static func displayed(_ reason: CleanupReason, home: URL) -> CleanupReason {
        switch reason {
        case .shadowedBy(let path): .shadowedBy(path: tilde(path, home))
        case .samePlaceAs(let path): .samePlaceAs(path: tilde(path, home))
        case .nestedIn(let parent): .nestedIn(parent: tilde(parent, home))
        case .olderCopyWins(let version, let newer, let newerVersion):
            .olderCopyWins(version: version, newer: tilde(newer, home), newerVersion: newerVersion)
        case .keptInstead(let path): .keptInstead(path: tilde(path, home))
        default: reason
        }
    }

    private static func displayed(_ instruction: CleanupInstruction, home: URL) -> CleanupInstruction {
        switch instruction {
        case .removeAppLinkWithAdminRights(let link):
            .removeAppLinkWithAdminRights(link: tilde(link, home))
        case .editShellFiles(let entry, let locations):
            .editShellFiles(
                entry: tilde(entry, home),
                locations: locations.map { CleanupShellFileLocation(file: tilde($0.file, home), line: $0.line) }
            )
        case .removeWithCreatingTool, .switchOffInFilesAndFolders:
            instruction
        }
    }
}

// MARK: - PATH hygiene advice

extension CleanupPresentation {
    /// The note of a row whose action is an instruction. A `PATH` hygiene row's shell-file advice
    /// follows its reason: removing an entry that lies inside another, or the folder that holds a
    /// tool's active copy, would take a whole folder of tools off `PATH`.
    private static func instructionNote(for finding: CleanupFinding, _ instruction: CleanupInstruction, home: URL) -> String {
        let shown = displayed(instruction, home: home)
        guard finding.detector == .pathHygiene, case .editShellFiles(let entry, let locations) = shown else {
            return instructionText(shown)
        }
        return shellFileAdvice(for: finding.reason, entry: entry, locations: locations, home: home)
    }

    /// `entry` and `locations` are shown as given, with `~` already substituted; the paths inside
    /// `reason` are the finding's own. A dead or same-place entry, like any other reason, is
    /// removed where it is added.
    private static func shellFileAdvice(
        for reason: CleanupReason, entry: String, locations: [CleanupShellFileLocation], home: URL
    ) -> String {
        let places = placesText(locations)
        switch reason {
        case .repeatedPathEntry:
            if locations.isEmpty { return dynamicEntryText(entry) + " " + tr("Zadbaj, żeby był dodawany tylko raz.") }
            if locations.count == 1 { return trf("Zostaw w PATH tylko jeden wpis %@. Ten wpis pochodzi z %@.", entry, places) }
            return trf("Zostaw tylko jedną z linii, które dodają wpis %@: %@.", entry, places)
        case .nestedIn(let parent):
            let parent = tilde(parent, home)
            if locations.isEmpty {
                return dynamicEntryText(entry) + " "
                    + trf("W PATH jest też zawierający go katalog %@. Sprawdź, czy potrzebujesz obu.", parent)
            }
            if locations.count == 1 {
                return trf(
                    "W PATH jest i ten katalog, i zawierający go katalog %@. Sprawdź, czy potrzebujesz obu. Ten wpis pochodzi z %@.",
                    parent, places
                )
            }
            return trf(
                "W PATH jest i ten katalog, i zawierający go katalog %@. Sprawdź, czy potrzebujesz obu. Ten wpis pochodzi z kilku miejsc: %@.",
                parent, places
            )
        case .olderCopyWins(_, let newer, _):
            let newerDirectory = tilde(URL(filePath: newer, directoryHint: .notDirectory).deletingLastPathComponent().path, home)
            if locations.isEmpty {
                return dynamicEntryText(entry) + " " + trf("Przesuń %@ w PATH przed ten wpis albo usuń starszą kopię.", newerDirectory)
            }
            if locations.count == 1 {
                return trf(
                    "Przesuń %@ w PATH przed %@ albo usuń starszą kopię. Katalog starszej kopii pochodzi z %@.",
                    newerDirectory, entry, places
                )
            }
            return trf(
                "Przesuń %@ w PATH przed %@ albo usuń starszą kopię. Katalog starszej kopii pochodzi z kilku miejsc: %@.",
                newerDirectory, entry, places
            )
        default:
            guard locations.isEmpty else { return removeEntryText(entry, locations: locations) }
            return dynamicEntryText(entry) + " " + tr("Usuń go tam, gdzie jest dodawany.")
        }
    }

    /// The plain shell-file instruction: remove the entry from every place that adds it, or say
    /// that no file Wega checks adds it.
    private static func removeEntryText(_ entry: String, locations: [CleanupShellFileLocation]) -> String {
        switch locations.count {
        case 0: dynamicEntryText(entry)
        case 1: trf("Usuń wpis %@ z pliku powłoki, który go dodaje: %@.", entry, placesText(locations))
        default: trf("Usuń wpis %@ ze wszystkich miejsc, które go dodają: %@.", entry, placesText(locations))
        }
    }

    private static func dynamicEntryText(_ entry: String) -> String {
        trf(
            "Wpisu %@ nie ma w plikach powłoki, które sprawdza Wega. Dodał go prawdopodobnie eval, dołączony plik, menedżer wtyczek albo ZDOTDIR.",
            entry
        )
    }

    private static func placesText(_ locations: [CleanupShellFileLocation]) -> String {
        locations.map { "\($0.file):\($0.line)" }.joined(separator: ", ")
    }
}

// MARK: - Files and Folders

extension CleanupPresentation {
    /// What the Files and Folders section can show, from the live switch and the report's D10 output.
    private enum MapState: Equatable {
        /// The switch is off; a map in the report is not shown.
        case off
        /// The switch is on, but the report was scanned while it was off (no D10 finding or note).
        case notScanned
        /// The scan tried and read no map; its notes say why. `openedDatabase`: the database was
        /// opened (it was empty or of an unknown layout), so Wega had Full Disk Access.
        case notRead(openedDatabase: Bool)
        case read
    }

    private static func mapState(of report: CleanupReport, tccMapEnabled: Bool) -> MapState {
        guard tccMapEnabled else { return .off }
        if report.findings.contains(where: { $0.detector == .tccMap }) { return .read }
        let mapNotes = report.notes.filter { $0.detector == .tccMap }
        guard !mapNotes.isEmpty else { return .notScanned }
        return .notRead(openedDatabase: mapNotes.contains { $0.kind == .tccMapEmpty || $0.kind == .tccUnsupportedSchema })
    }

    private static func withoutMap(_ report: CleanupReport) -> CleanupReport {
        CleanupReport(
            createdAt: report.createdAt, path: report.path,
            findings: report.findings.filter { $0.detector != .tccMap },
            notes: report.notes.filter { $0.detector != .tccMap },
            skippedProtected: report.skippedProtected
        )
    }

    /// `mapNotes` and `mapRows` are the report's D10 notes and rows; `offRows` lists what may have
    /// entries while the switch is off. Every scan that opened the database repeats the Full Disk
    /// Access reminder, whether or not the map had rows.
    private static func filesAndFoldersSection(_ state: MapState, notes mapNotes: [String], rows mapRows: [Row], offRows: [Row]) -> Section {
        let reminder = tr("Pełny dostęp do dysku, którego Wega potrzebuje do mapy, macOS daje też każdemu programowi, który Wega uruchamia: brew, npm, mas i powłoce, z której Wega odczytuje PATH. Gdy skończysz przeglądać mapę, usuń Wegę z listy Pełny dostęp do dysku.")
        let explanation = [
            tr("Narzędzie wiersza poleceń nie ma pakietu aplikacji, więc macOS zapisuje zgodę na dostęp do plików osobno dla każdej ścieżki, z której zostało uruchomione."),
            tr("Każda kopia z sekcji „Wiele kopii tego samego narzędzia” może mieć w Ustawieniach systemowych → Prywatność i ochrona → Pliki i foldery własny wpis."),
        ]
        let (notes, rows): ([String], [Row]) = switch state {
        case .off:
            (explanation + [tr("Mapa, która przypisuje te wpisy do konkretnych kopii, jest wyłączona. Włącz ją w Ustawieniach.")], offRows)
        case .notScanned:
            (explanation + [tr("Mapa jest włączona. Kliknij „Skanuj”, żeby ją odczytać.")], [])
        case .notRead(let openedDatabase):
            (openedDatabase ? mapNotes + [reminder] : mapNotes, [])
        case .read:
            (mapNotes + [reminder, tr("Wpisów Pełnego dostępu do dysku Wega nie mapuje: macOS trzyma je w bazie systemowej.")], mapRows)
        }
        return Section(kind: .filesAndFolders, title: tr("Wpisy w „Pliki i foldery”"), notes: notes, rows: rows)
    }

    /// With the map off: each tool with two or more copies on `PATH` that are not the system's
    /// expected copy, then each copy an app manages. Each may have its own entry; no finding stands
    /// behind these rows, so they offer nothing.
    private static func mayHaveEntriesRows(_ findings: [CleanupFinding], home: URL) -> [Row] {
        var tools: [String] = []
        var copies: [String: Int] = [:]
        for finding in findings where finding.detector == .pathDuplicates && finding.status != .expected {
            if copies[finding.tool] == nil { tools.append(finding.tool) }
            copies[finding.tool, default: 0] += 1
        }
        let toolRows = tools.compactMap { tool -> Row? in
            guard let count = copies[tool], count >= 2 else { return nil }
            return mayHaveEntriesRow(title: tool, detail: trf("kopie w PATH: %@", "\(count)"))
        }
        let appRows = findings.filter { $0.status == .appManaged }.map { finding in
            mayHaveEntriesRow(title: tilde(finding.path.path, home), detail: finding.source.map(sourceText) ?? finding.tool)
        }
        return toolRows + appRows
    }

    private static func mayHaveEntriesRow(title: String, detail: String) -> Row {
        Row(
            findingID: nil, groupHeader: nil, bucket: nil, status: tr("może mieć wpisy"), title: title, detail: detail,
            sizeText: nil, button: nil, note: tr("tylko informacja")
        )
    }

    /// Every row of a finding a map entry is tied to (a copy on `PATH`, a version directory, an
    /// app's copy) names the services of its entries, so the copies say which entry is which.
    private static func addingLinkedEntries(to sections: [Section], from findings: [CleanupFinding]) -> [Section] {
        var services: [String: [CleanupTCCService]] = [:]
        for finding in findings where finding.detector == .tccMap {
            guard case .tccEntry(let grants, let link?) = finding.reason else { continue }
            for grant in grants where services[link.findingID]?.contains(grant.service) != true {
                services[link.findingID, default: []].append(grant.service)
            }
        }
        return sections.map { section in
            let rows = section.rows.map { row in
                guard let id = row.findingID, let linked = services[id] else { return row }
                return row.appendingDetail(trf("wpisy w „Pliki i foldery”: %@", linked.map(serviceName).joined(separator: ", ")))
            }
            return Section(kind: section.kind, title: section.title, notes: section.notes, rows: rows)
        }
    }

    /// A Files and Folders entry of an app is recorded by its bundle id; the row shows that id
    /// rather than the database file the finding points at.
    private static func isMapBundleEntry(_ finding: CleanupFinding) -> Bool {
        guard finding.detector == .tccMap, case .appBundle = finding.source else { return false }
        return true
    }
}
