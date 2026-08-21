import Foundation

/// Jeden wiersz metryczki środowiska w zgłoszeniu: `- Homebrew: 4.3.0`.
///
/// Etykiety są angielskie i stabilne — zgłoszenie to wymiana danych między użytkownikiem
/// a maintainerem i musi czytać się tak samo niezależnie od języka UI, dokładnie jak
/// ``DiagnosticsBundle``.
public struct ReportField: Sendable, Equatable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Zwęża ``DiagnosticsSnapshot`` do tych kilku faktów, o które maintainer i tak zawsze
/// dopytuje. Nie zbiera niczego sam: pełny snapshot jest już budowany na potrzeby paczki
/// diagnostycznej, a to jest jego widok, nie drugie źródło prawdy.
public enum BugReportEnvironment {

    public static func fields(from snapshot: DiagnosticsSnapshot) -> [ReportField] {
        var fields: [ReportField] = [
            ReportField(label: "Wega", value: "\(snapshot.appVersion) (\(snapshot.appBuild))"),
            ReportField(label: "macOS", value: "\(snapshot.osVersion) (\(snapshot.architecture))"),
        ]
        for manager in snapshot.managers {
            fields.append(ReportField(
                label: manager.name,
                value: manager.detected ? (manager.version ?? "detected, version unknown") : "not detected"
            ))
        }
        fields.append(ReportField(label: "Privileged helper", value: snapshot.helper.status))
        fields.append(ReportField(label: "Last scan", value: lastScan(snapshot)))
        return fields
    }

    private static func lastScan(_ snapshot: DiagnosticsSnapshot) -> String {
        guard let date = snapshot.lastScanAt else { return "never" }
        let stamp = iso.string(from: date)
        return snapshot.lastScanComplete ? "\(stamp) (complete)" : "\(stamp) (incomplete)"
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
