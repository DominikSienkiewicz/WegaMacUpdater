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
            case duplicates, shellState, protectedLocations, filesAndFolders
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

    /// The stage-1 sections in order: copies of one tool (grouped by tool), shell state, skipped
    /// protected locations (only when there are some) and the "Files and Folders" explanation.
    static func sections(_ report: CleanupReport, home: URL) -> [Section] {
        let isProtected: (CleanupFinding) -> Bool = { $0.status == .skippedProtected }
        let copies = report.findings.filter { !isProtected($0) && $0.detector != .shellState }
        let shellState = report.findings.filter { !isProtected($0) && $0.detector == .shellState }
        let shellNotes = report.notes.filter { $0.detector == .shellState }.map(noteText)
        var copyNotes = report.notes.filter { $0.detector != .shellState }.map(noteText)
        if report.path.isApproximate, copies.contains(where: { $0.detector == .pathDuplicates }) {
            copyNotes.append(trf(
                "PATH jest %@, więc to, która kopia jest aktywna, może się różnić od Terminala. Odczytaj PATH z powłoki, żeby to potwierdzić.",
                tr("przybliżony")
            ))
        }

        var sections = [
            section(.duplicates, tr("Wiele kopii tego samego narzędzia"), notes: copyNotes,
                    rows: groupedRows(copies, home: home), empty: tr("Nie znaleziono kopii ani starych wersji narzędzi.")),
            section(.shellState, tr("Stan powłok"), notes: shellNotes,
                    rows: shellState.map { row(for: $0, home: home, groupHeader: nil, namesTool: true) },
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
        case .dependency, .brokenLink: 2
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

    /// The button comes from the finding's action alone; an excluded finding never offers one.
    private static func control(for finding: CleanupFinding, home: URL) -> (button: ButtonKind?, note: String?) {
        guard finding.bucket != .excluded else { return (nil, tr("tylko informacja")) }
        switch finding.action {
        case .trash, .trashBatch: return (.trash, nil)
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
        parts.append(reasonText(displayed(finding.reason, home: home)))
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
        case .info: tr("informacja")
        }
    }

    /// Paths inside a reason are shown as given; callers pass them with `~` already substituted.
    static func reasonText(_ reason: CleanupReason) -> String {
        switch reason {
        case .olderVersion(let current): trf("starsza wersja; bieżąca to %@", current)
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
            reason: reasonText(displayed(finding.reason, home: home)),
            action: actionText(finding.action, home: home),
            risk: riskText(finding.risk),
            processes: processes(in: finding.status).map(processLine),
            confirmTitle: finding.action.isBrew ? tr("Odinstaluj") : tr("Przenieś do Kosza")
        )
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

    /// Homebrew commands are spelled exactly as `CleanupReportRenderer.text` writes them.
    private static func actionText(_ action: CleanupAction, home: URL) -> String {
        switch action {
        case .trash(let urls):
            trf("Przeniesienie do Kosza: %@", urls.map { tilde($0.path, home) }.joined(separator: ", "))
        case .trashBatch(let parent, let entries):
            trf("Przeniesienie do Kosza — liczba wpisów: %@, folder: %@", "\(entries.count)", tilde(parent.path, home))
        case .brew(.uninstallFormula(let name)):
            "brew uninstall -- \(name)"
        case .brew(.uninstallCask(let token)):
            "brew uninstall --cask -- \(token)"
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

    private static func displayed(_ reason: CleanupReason, home: URL) -> CleanupReason {
        guard case .shadowedBy(let path) = reason else { return reason }
        return .shadowedBy(path: tilde(path, home))
    }

    private static func displayed(_ instruction: CleanupInstruction, home: URL) -> CleanupInstruction {
        guard case .removeAppLinkWithAdminRights(let link) = instruction else { return instruction }
        return .removeAppLinkWithAdminRights(link: tilde(link, home))
    }
}

private extension CleanupAction {
    var isBrew: Bool {
        if case .brew = self { return true }
        return false
    }
}
