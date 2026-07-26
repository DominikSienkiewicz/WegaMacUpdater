import Foundation

/// REL-14: a single scan input that failed. Inventory and Uninstall used to drop every
/// source error (`(try? …) ?? []`), so a broken brew/scanner produced a silently partial
/// table or an empty list indistinguishable from "nothing installed". Collecting the
/// failure per source lets the UI name what is missing and tell "empty" apart from
/// "the scan couldn't complete".
/// Named `ScanFailureSource`, not `ScanSource`: `MacUpdaterCore.ScanSource` (UX-06) already
/// names the update sources a scan CHECKS, while this one names the inputs that can FAIL.
/// Two different concepts — an unqualified `ScanSource` inside this module would silently
/// resolve here and hide the Core type.
enum ScanFailureSource: Equatable, Sendable {
    case homebrew
    case caskCatalog
    case applications
    case appStore
    case npm

    /// Human name shown in the error banner. Localized — keep `Translations.en` in sync.
    var label: String {
        switch self {
        case .homebrew:     return tr("Homebrew")
        case .caskCatalog:  return tr("katalog Homebrew")
        case .applications: return tr("skan aplikacji")
        case .appStore:     return "App Store"
        case .npm:          return tr("pakiety npm")
        }
    }
}

struct ScanSourceFailure: Equatable, Sendable {
    let source: ScanFailureSource
    let message: String
}

extension Array where Element == ScanSourceFailure {
    /// Banner text naming every source that failed, or `nil` when the scan was clean.
    /// A non-`nil` value is the signal a view uses to render the error banner and to
    /// distinguish "empty" from "scan failed".
    var scanErrorMessage: String? {
        guard !isEmpty else { return nil }
        let names = map(\.source.label).joined(separator: ", ")
        return trf("Część źródeł skanu zawiodła (%@) — lista może być niekompletna.", names)
    }
}

/// REL-14: the Uninstall list distinguishes an empty machine from a failed scan so a
/// scan failure is never reported as "no apps found". A partial scan (some apps, some
/// failed sources) still renders the apps — the error banner above the list carries the
/// warning — so it resolves to `.populated`, not `.scanFailed`.
enum UninstallListState: Equatable {
    case loading
    case scanFailed
    case empty
    case populated

    static func resolve(isLoading: Bool, appsEmpty: Bool, scanFailed: Bool) -> UninstallListState {
        if isLoading { return .loading }
        guard appsEmpty else { return .populated }
        return scanFailed ? .scanFailed : .empty
    }
}
