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
    }

    struct Section: Equatable {
        enum Kind: Hashable {
            case duplicates, homebrew, runtimes, gradle, jetBrains, shellState, protectedLocations, filesAndFolders
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
        /// The processes that used the item during the scan, arguments included. Shown live only.
        let processes: [String]
        let confirmTitle: String
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

        func data(_ report: CleanupReport, home: URL) throws -> Data {
            switch self {
            case .text: Data(CleanupPresentation.exportText(report, home: home).utf8)
            case .json: try CleanupReportRenderer.json(report, home: home)
            }
        }
    }

    /// A shell read older than this is offered for a refresh.
    static let pathRefreshInterval: TimeInterval = 7 * 86_400

    // MARK: - Sections

    /// The sections in the sidebar sketch's order: copies of one tool, Homebrew leftovers, version
    /// managers, Gradle, JetBrains, shell state, skipped protected locations (only when there are
    /// some) and the "Files and Folders" explanation. Each detector's findings and notes go to its
    /// own section, and every section but the shell state groups its rows by tool.
    static func sections(_ report: CleanupReport, home: URL) -> [Section] {
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
        ]
        let skipped = report.skippedProtected.map { skippedRow($0, home: home) }
            + report.findings.filter(isProtected).map { row(for: $0, home: home, groupHeader: nil, namesTool: true) }
        if !skipped.isEmpty {
            sections.append(Section(kind: .protectedLocations, title: tr("Pominięte lokalizacje chronione"), notes: [], rows: skipped))
        }
        sections.append(Section(kind: .filesAndFolders, title: tr("Wpisy w „Pliki i foldery”"), notes: [
            tr("Narzędzie wiersza poleceń nie ma pakietu aplikacji, więc macOS zapisuje zgodę na dostęp do plików osobno dla każdej ścieżki, z której zostało uruchomione."),
            tr("Każda kopia z sekcji „Wiele kopii tego samego narzędzia” może mieć w Ustawieniach systemowych → Prywatność i ochrona → Pliki i foldery własny wpis."),
            tr("Mapa, która przypisze te wpisy do konkretnych kopii, pojawi się w kolejnej wersji jako opcja w Ustawieniach."),
        ], rows: []))
        return sections
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
    private static func groupedRows(_ findings: [CleanupFinding], home: URL) -> [Row] {
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
                row(for: finding, home: home, groupHeader: index == 0 ? members.first?.tool : nil, namesTool: false)
            }
        }
    }

    /// The active copy first, then what may go, then what stays.
    private static func rank(_ status: CleanupStatus) -> Int {
        switch status {
        case .active: 0
        case .shadowed, .unused, .stale, .inUse: 1
        case .dependency, .brokenLink, .pinned, .recentUpgrade: 2
        case .expected, .appManaged, .info, .skippedProtected: 3
        }
    }

    private static func row(for finding: CleanupFinding, home: URL, groupHeader: String?, namesTool: Bool) -> Row {
        let control = control(for: finding, home: home)
        return Row(
            findingID: finding.id, groupHeader: groupHeader, bucket: finding.bucket, status: statusText(finding.status),
            title: tilde(finding.path.path, home), detail: detail(of: finding, home: home, namesTool: namesTool),
            sizeText: finding.size.map(sizeText), button: control.button, note: control.note
        )
    }

    /// The button comes from the finding's action alone; an excluded finding never offers one. A
    /// JetBrains folder offered for the Trash also names the IDE's own cleanup, which knows its
    /// folders best.
    private static func control(for finding: CleanupFinding, home: URL) -> (button: ButtonKind?, note: String?) {
        guard finding.bucket != .excluded else { return (nil, tr("tylko informacja")) }
        switch finding.action {
        case .trash, .trashBatch:
            guard finding.detector == .jetBrains else { return (.trash, nil) }
            return (.trash, tr("Zalecane: w IDE wybierz Help → Delete Leftover IDE Directories. Wega może też przenieść ten katalog do Kosza."))
        case .brew(.cleanup): return (.brewCleanup, nil)
        case .brew: return (.brew, nil)
        case .command(let command): return (.copyCommand(command), command)
        case .instruction(let instruction): return (nil, instructionText(displayed(instruction, home: home)))
        case .none: return (nil, tr("tylko informacja"))
        }
    }

    private static func detail(of finding: CleanupFinding, home: URL, namesTool: Bool) -> String {
        var parts: [String] = namesTool ? [finding.tool] : []
        if let source = finding.source { parts.append(sourceText(source)) }
        if let version = finding.version {
            parts.append(version)
        } else if finding.source == .standalone, finding.status != .brokenLink {
            parts.append(tr("wersja nieznana"))
        }
        parts.append(reasonText(displayed(finding.reason, home: home), requiredBy: pinnedPaths(in: finding.status, home: home)))
        let users = processes(in: finding.status)
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
        case nil, .captured: nil
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
        }
    }

    static func instructionText(_ instruction: CleanupInstruction) -> String {
        switch instruction {
        case .removeWithCreatingTool:
            tr("Usuń ją narzędziem, które ją zainstalowało.")
        case .removeAppLinkWithAdminRights(let link):
            trf("Dowiązanie %@ prowadzi do aplikacji; usuń je ręcznie, z uprawnieniami administratora.", link)
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
            processes: processes(in: finding.status).map(processLine),
            confirmTitle: confirmTitle(for: finding.action)
        )
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
        case .instruction(let instruction):
            instructionText(displayed(instruction, home: home))
        case .none:
            tr("tylko informacja")
        }
    }

    // MARK: - Export

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
        let findings = CleanupReportRenderer.text(report, home: home, reasonText: reasonText, statusText: statusText)
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

    private static func processes(in status: CleanupStatus) -> [CleanupProcess] {
        guard case .inUse(let processes) = status else { return [] }
        return processes
    }

    private static func pinnedPaths(in status: CleanupStatus, home: URL) -> [String] {
        guard case .pinned(let paths) = status else { return [] }
        return paths.map { tilde($0, home) }
    }

    private static func displayed(_ reason: CleanupReason, home: URL) -> CleanupReason {
        guard case .shadowedBy(let path) = reason else { return reason }
        return .shadowedBy(path: tilde(path, home))
    }

    private static func displayed(_ instruction: CleanupInstruction, home: URL) -> CleanupInstruction {
        guard case .removeAppLinkWithAdminRights(let link) = instruction else { return instruction }
        return .removeAppLinkWithAdminRights(link: tilde(link, home))
    }
}
