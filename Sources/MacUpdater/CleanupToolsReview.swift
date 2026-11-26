import Foundation
import MacUpdaterCore

/// The review cards and secondary sections of the Tools tab, derived from the same report as its export.
struct CleanupToolsReview {
    typealias Presentation = CleanupPresentation

    struct Card: Identifiable {
        let id: String
        let kind: Presentation.Section.Kind
        let group: Presentation.ToolGroup
        let title: String
        let subtitle: String?
        let quickAction: Presentation.Row?
        let firstInShell: String?
        let approximateOrder: Bool
    }

    struct Area: Identifiable {
        var id: Presentation.Section.Kind { section.kind }
        let section: Presentation.Section
        let quiet: [Presentation.QuietItem]
    }

    var cards: [Card] = []
    var checked: [Area] = []
    var scope: [Area] = []
    let shellOrder: [String: Int]
    let warnings: [String]
    let mapAccessReminder: String?
    var count = 0
    var checkedTitle = tr("Sprawdzone obszary bez uwag")
    var inspectedToolMessage: String?

    init(report: CleanupReport, home: URL, mapEnabled: Bool, search: String, inspectedTool: String?) {
        let sections = Presentation.sections(report, home: home, tccMapEnabled: mapEnabled)
        let notes = report.notes.filter { ($0.detector != .tccMap || mapEnabled) && $0.kind != .tccMapEmpty }
        var limitations = Set(notes.flatMap(Presentation.sectionKinds))
        limitations.formUnion([.filesAndFolders, .protectedLocations])
        if report.path.isApproximate { limitations.formUnion([.duplicates, .pathHygiene]) }
        var seen = Set<String>()
        warnings = notes.map(Presentation.noteText).filter { seen.insert($0).inserted }
        mapAccessReminder = sections.contains { $0.kind == .filesAndFolders && $0.notes.contains(Presentation.mapAccessReminder) }
            ? Presentation.mapAccessReminder : nil
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let directories = report.path.entries.enumerated().filter { $0.element.hasPrefix("/") }.map { (Self.directoryKey($0.element), $0.offset) }
        shellOrder = report.path.isApproximate ? [:] : Dictionary(directories, uniquingKeysWith: min)
        if let inspectedTool, !report.path.isApproximate, !notes.contains(where: { $0.detector == .pathDuplicates && $0.kind == .failed }),
           !report.findings.contains(where: { $0.detector == .pathDuplicates && $0.tool == inspectedTool }) {
            inspectedToolMessage = trf("Po sprawdzeniu ścieżki Terminala Wega nie znalazła kilku kopii %@.", inspectedTool)
        }
        for section in sections {
            guard let full = Presentation.layout(of: section, search: "", inspectedTool: inspectedTool) else { continue }
            count += full.actionCount
            let area = Area(section: section, quiet: full.quiet)
            if limitations.contains(section.kind) || (section.kind == .duplicateApplications && !section.notes.isEmpty) {
                scope.append(area)
            } else if !full.quiet.isEmpty || section.rows.isEmpty {
                checked.append(area)
                if !full.shown.isEmpty { checkedTitle = tr("Pozostałe sprawdzone pozycje") }
            }
            let groups = query.isEmpty ? full.shown : Presentation.toolGroups(of: section)
            for group in groups {
                let card = Self.card(group, in: section, order: shellOrder)
                if query.isEmpty || group.matches(query) || card.title.localizedStandardContains(query)
                    || card.subtitle?.localizedStandardContains(query) == true {
                    cards.append(card)
                }
            }
        }
    }

    private static func directoryKey(_ path: String) -> String {
        path.split(separator: "/").joined(separator: "/")
    }

    var headline: String {
        if count > 0 { return trp("%@ wyników do przejrzenia", count) }
        return warnings.isEmpty ? tr("Brak wyników do przejrzenia w sprawdzonych obszarach.") : tr("Skan zakończony z uwagami")
    }

    private static func card(_ group: Presentation.ToolGroup, in section: Presentation.Section, order: [String: Int]) -> Card {
        let first = group.rows.first?.finding
        let row = group.rows.first
        let copies = group.workingCopies
        var firstInShell: String?
        let name = group.name ?? first?.tool ?? section.title
        let title: String
        let subtitle: String?
        var key = row?.findingID ?? row?.title ?? name
        if copies.count > 1 {
            key = "tool/" + name.lowercased()
            title = copies.count == 2
                ? trf("%@ jest w dwóch miejscach", name) : trf("%@ jest w kilku miejscach", name)
            var seen = Set<String>()
            if let first = firstCopy(in: copies, order: order), let source = friendlySource(first.source) {
                firstInShell = first.id
                subtitle = trf("Pierwsza w ścieżce Terminala: %@", source)
            } else {
                subtitle = copies.compactMap { friendlySource($0.source) }.filter { seen.insert($0).inserted }.joined(separator: " · ")
            }
        } else if case .duplicateApplication(let bundle)? = first?.reason {
            key = "app/" + bundle
            title = trf("Kilka kopii aplikacji %@", name)
            subtitle = tr("Porównaj lokalizacje i wersje aplikacji.")
        } else {
            let representative = group.rows.first { $0.isActionable } ?? row
            (title, subtitle) = summary(representative?.finding, row: representative, section: section)
        }
        let quickAction: Presentation.Row?
        if case .copyCommand = row?.button {
            quickAction = nil
        } else {
            quickAction = (group.rows.count == 1 || section.kind == .duplicateApplications) && row?.keep == nil && row?.button != nil ? row : nil
        }
        return Card(id: section.kind.rawValue + "/" + key, kind: section.kind, group: group, title: title,
                    subtitle: subtitle, quickAction: quickAction, firstInShell: firstInShell,
                    approximateOrder: section.approximateCopyOrder)
    }

    static func firstCopy(in copies: [CleanupFinding], order: [String: Int]) -> CleanupFinding? {
        guard !order.isEmpty else { return nil }
        let located = copies.compactMap { finding -> (CleanupFinding, Int)? in
            let parent = (finding.path.path as NSString).deletingLastPathComponent
            return order[directoryKey(parent)].map { (finding, $0) }
        }
        guard located.count == copies.count else { return nil }
        return located.min(by: { $0.1 < $1.1 })?.0
    }

    static func friendlySource(_ source: CleanupSource?) -> String? {
        switch source {
        case .homebrewFormula, .homebrewCask: tr("Kopia z Homebrew")
        case .system: tr("Kopia systemowa")
        case .some(let source): Presentation.sourceText(source)
        case nil: nil
        }
    }

    private static func summary(_ finding: CleanupFinding?, row: Presentation.Row?, section: Presentation.Section) -> (String, String?) {
        guard let finding else { return (row?.title ?? section.title, row?.status) }
        let name = finding.tool
        let versioned = [name, finding.version].compactMap { $0 }.joined(separator: " ")
        let title: String
        var detail: String?
        switch finding.reason {
        case .homebrewLeftovers:
            title = trf("Homebrew ma pliki po aktualizacji %@", name)
            detail = tr("Starsze wersje lub pobrane pliki")
        case .unusedGradleDistribution:
            title = trf("Pliki Gradle %@", finding.version ?? name)
            detail = tr("Żaden ze sprawdzonych projektów nie wskazuje tej dystrybucji.")
        case .installedOnlyAsDependency:
            title = trf("Pakiet %@ do przejrzenia", name)
        case .olderVersion, .ideVersionNotInstalled:
            title = trf("Pliki poprzedniej wersji %@", versioned)
        case .notRequiredByProjects, .unreferencedJDK:
            title = versioned
            detail = tr("Wega nie znalazła odwołania w sprawdzonych projektach.")
        case .staleSinceBoot:
            title = trf("Pliki poprzednich sesji %@", name)
        case .brokenLink:
            title = trf("Niedziałający skrót do %@", name)
        case .missingPathEntry, .repeatedPathEntry, .nestedIn, .samePlaceAs, .olderCopyWins:
            title = tr("Kolejność wyszukiwania narzędzi w Terminalu")
            detail = finding.path.lastPathComponent
        default:
            title = versioned
            detail = row?.status
        }
        if case .inUse = finding.status { detail = Presentation.statusText(finding.status) }
        let parts = [detail, row?.sizeText].compactMap { $0 }
        return (title, parts.isEmpty ? nil : parts.joined(separator: " · "))
    }
}

extension CleanupPresentation.Section.Kind {
    var icon: String {
        switch self {
        case .duplicates: "square.on.square"
        case .duplicateApplications: "macwindow.on.rectangle"
        case .homebrew: "shippingbox"
        case .runtimes: "square.stack.3d.up"
        case .gradle: "hammer"
        case .jetBrains: "chevron.left.forwardslash.chevron.right"
        case .shellState: "terminal"
        case .pathHygiene: "arrow.triangle.branch"
        case .protectedLocations: "lock.shield"
        case .filesAndFolders: "hand.raised"
        }
    }
}
