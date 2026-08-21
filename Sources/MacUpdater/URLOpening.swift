import AppKit
import Foundation

/// Otwieranie URL-a przez system, za wstrzykiwaną granicą.
///
/// Istnieje wyłącznie po to, żeby ścieżka „na tej maszynie nie ma klienta poczty" była
/// testowalna. Bez niej dałoby się ją sprawdzić tylko odinstalowując klienta poczty
/// z maszyny, na której lecą testy.
protocol URLOpening: Sendable {
    /// Czy system ma czymkolwiek obsłużyć ten URL.
    func canOpen(_ url: URL) -> Bool
    /// Otwiera URL. `false`, gdy system odmówił.
    @discardableResult
    func open(_ url: URL) -> Bool
}

struct WorkspaceURLOpener: URLOpening {
    func canOpen(_ url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
