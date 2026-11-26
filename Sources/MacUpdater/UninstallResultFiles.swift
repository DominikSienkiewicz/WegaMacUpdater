import Foundation
import MacUpdaterCore

struct UninstallFileResult: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case movedToTrash, alreadyAbsent
        case failed(String?)
        case keptForApp(String)
        case keptForAnotherApp
        case unconfirmed
    }

    let url: URL
    let status: Status

    var id: URL { url }

    var reason: String {
        switch status {
        case .movedToTrash: tr("Przeniesiono do Kosza.")
        case .alreadyAbsent: tr("Pozycji nie było już pod tą ścieżką.")
        case .failed(let message): message.map { trf("Nie udało się przenieść do Kosza. %@", $0) }
            ?? tr("Nie udało się przenieść do Kosza.")
        case .keptForApp(let name): trf("Pominięto, ponieważ usunięcie aplikacji %@ nie zostało potwierdzone.", name)
        case .keptForAnotherApp: tr("Pominięto, aby zachować dane innej aplikacji lub kopii.")
        case .unconfirmed: tr("Brak potwierdzenia przeniesienia do Kosza.")
        }
    }

    var action: UninstallResultAction? {
        switch status {
        case .movedToTrash, .alreadyAbsent: nil
        case .failed, .keptForApp, .keptForAnotherApp, .unconfirmed: .showInFinder(url)
        }
    }
}

struct UninstallFileGroup: Identifiable, Equatable {
    enum Kind: CaseIterable {
        case trashed, absent, remaining
    }

    let id: Kind
    let files: [UninstallFileResult]

    var title: String {
        let count = String(files.count)
        switch id {
        case .trashed: return trf("Przeniesiono do Kosza (%@)", count)
        case .absent: return trf("Już nie było na dysku (%@)", count)
        case .remaining: return trf("Pozostało (%@)", count)
        }
    }

    static func groups(for files: [UninstallFileResult]) -> [Self] {
        let grouped = Dictionary(grouping: files) { file -> Kind in
            switch file.status {
            case .movedToTrash: .trashed
            case .alreadyAbsent: .absent
            case .failed, .keptForApp, .keptForAnotherApp, .unconfirmed: .remaining
            }
        }
        return Kind.allCases.compactMap { kind in
            grouped[kind].map { Self(id: kind, files: $0) }
        }
    }
}

/// The planner has already deduplicated paths. Retain its order and decisions through execution
/// so every consented path has one outcome, even when its app was skipped.
struct UninstallFilePlan {
    private struct Entry {
        let url: URL
        let retained: UninstallFileResult.Status?
    }
    private let entries: [Entry]

    init(groups: [LeftoverGroup], results: [String: UninstallTargetResult], preservedAppIDs: Set<String> = []) {
        let mayReleaseData = { (id: String) in
            results[id]?.isRemoved == true && !preservedAppIDs.contains(id)
        }
        entries = groups.flatMap { group in
            group.items.map { item in
                let retained: UninstallFileResult.Status?
                if results[group.id]?.isRemoved != true {
                    retained = .keptForApp(group.app.name)
                } else if preservedAppIDs.contains(group.id) || !item.coTargets.allSatisfy(mayReleaseData) {
                    retained = .keptForAnotherApp
                } else {
                    retained = nil
                }
                return Entry(url: item.url, retained: retained)
            }
        }
    }

    var ready: [URL] { entries.filter { $0.retained == nil }.map(\.url) }

    func finished(_ cleanup: LeftoverCleanup.Result = .init()) -> [UninstallFileResult] {
        let absent = Set(cleanup.alreadyAbsent)
        let removed = Set(cleanup.removed)
        let failed = Set(cleanup.failed)
        return entries.map { entry in
            let status: UninstallFileResult.Status
            if let retained = entry.retained { status = retained }
            else if absent.contains(entry.url) { status = .alreadyAbsent }
            else if removed.contains(entry.url) { status = .movedToTrash }
            else if failed.contains(entry.url) { status = .failed(cleanup.failureReasons[entry.url]) }
            else { status = .unconfirmed }
            return UninstallFileResult(url: entry.url, status: status)
        }
    }
}
