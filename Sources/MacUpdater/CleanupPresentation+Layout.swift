import Foundation
import MacUpdaterCore

// MARK: - Section layout

extension CleanupPresentation {
    /// A tool's rows, from the row that names it up to the next one that does. A row outside any
    /// tool (shell state, a protected location) is a group of its own with no name.
    struct ToolGroup: Equatable {
        let name: String?
        var rows: [Row]
        var checkShellOrder = false

        var workingCopies: [CleanupFinding] {
            rows.compactMap(\.finding).filter { $0.detector == .pathDuplicates && $0.status != .brokenLink && $0.realpath != nil }
        }

        var isActionable: Bool { checkShellOrder || rows.contains(where: \.isActionable) }

        /// A keep radio stays in sight even when the choice leaves nothing to do, so a click on it
        /// does not move the tool out from under the pointer.
        var staysShown: Bool { isActionable || rows.contains { $0.keep != nil } }

        func matches(_ query: String) -> Bool {
            name?.localizedStandardContains(query) == true
                || rows.contains { $0.title.localizedStandardContains(query) || $0.detail.localizedStandardContains(query) }
        }
    }

    /// Tools without action whose first copy comes from one source and directory, as one line.
    struct OriginLine: Equatable {
        let origin: Row.Origin
        let tools: [ToolGroup]
        let title: String
        /// Where the tools' other copies live; nil when they have none.
        let companions: String?
    }

    enum QuietItem: Equatable {
        case tool(ToolGroup)
        case origin(OriginLine)
    }

    struct SectionLayout: Equatable {
        /// Groups shown expanded: the ones that need action, or every match while searching.
        let shown: [ToolGroup]
        /// What the collapsed "Bez akcji" group holds; empty while searching.
        let quiet: [QuietItem]
        let actionCount: Int
        /// Nil for a section with no rows, whose notes speak alone.
        let headerNote: String?
        /// The collapsed group's title; nil when there is nothing quiet to collapse.
        let quietTitle: String?
    }

    /// Nil only when a non-empty search matches nothing in the section. The counts always describe
    /// the whole section, so a search never changes what the header says.
    static func layout(of section: Section, search: String, inspectedTool: String? = nil) -> SectionLayout? {
        let groups = toolGroups(of: section)
        func isShown(_ group: ToolGroup) -> Bool {
            group.staysShown || (section.kind == .duplicates && inspectedTool != nil && inspectedTool == group.name && !group.workingCopies.isEmpty)
        }
        let actionCount = groups.filter(\.isActionable).count
        let headerNote: String? = section.rows.isEmpty
            ? nil : actionCount == 0 ? tr("nic do zrobienia") : trf("%@ do zrobienia", "\(actionCount)")
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let matching = groups.filter { $0.matches(query) }
            guard !matching.isEmpty else { return nil }
            return SectionLayout(shown: matching, quiet: [], actionCount: actionCount, headerNote: headerNote, quietTitle: nil)
        }
        let quietGroups = groups.filter { !isShown($0) }
        return SectionLayout(
            shown: groups.filter(isShown), quiet: quietItems(of: quietGroups), actionCount: actionCount,
            headerNote: headerNote,
            quietTitle: quietTitle(count: quietGroups.count, namesTools: section.rows.contains { $0.groupHeader != nil })
        )
    }

    static func toolGroups(of section: Section) -> [ToolGroup] {
        var groups: [ToolGroup] = []
        var name: String?
        var copyGroup: Int?
        for row in section.rows {
            if let header = row.groupHeader {
                name = header
                copyGroup = nil
            }
            let comparesCopies = section.kind == .duplicateApplications ||
                (section.kind == .duplicates && (row.finding == nil || row.finding?.detector == .pathDuplicates))
            if comparesCopies, let copyGroup {
                groups[copyGroup].rows.append(row)
            } else {
                if comparesCopies && name != nil { copyGroup = groups.count }
                groups.append(ToolGroup(name: name, rows: [row]))
            }
        }
        if section.approximateCopyOrder {
            for index in groups.indices {
                groups[index].checkShellOrder = groups[index].workingCopies.count > 1
            }
        }
        return groups
    }

    private static func quietTitle(count: Int, namesTools: Bool) -> String? {
        guard count > 0 else { return nil }
        return namesTools ? trp("Bez akcji: %@ narzędzi", count) : trp("Bez akcji: %@ pozycji", count)
    }

    private static func quietItems(of groups: [ToolGroup]) -> [QuietItem] {
        var items: [QuietItem] = []
        var merged = Set<Int>()
        for (index, group) in groups.enumerated() where !merged.contains(index) {
            guard let origin = group.rows.first?.origin else {
                items.append(.tool(group))
                continue
            }
            let sharing = groups.indices.filter { groups[$0].rows.first?.origin == origin }
            guard sharing.count >= 2 else {
                items.append(.tool(group))
                continue
            }
            merged.formUnion(sharing)
            items.append(.origin(originLine(origin, tools: sharing.map { groups[$0] })))
        }
        return items
    }

    private static func originLine(_ origin: Row.Origin, tools: [ToolGroup]) -> OriginLine {
        var elsewhere: [String] = []
        for other in tools.flatMap(\.rows).compactMap(\.origin) where other != origin {
            let text = "\(other.directory) (\(other.source))"
            if !elsewhere.contains(text) { elsewhere.append(text) }
        }
        return OriginLine(
            origin: origin, tools: tools,
            title: trp("%@ poleceń", tools.count) + " · " + origin.source + " · " + origin.directory,
            companions: elsewhere.isEmpty ? nil : trf("też: %@", elsewhere.joined(separator: ", "))
        )
    }
}
