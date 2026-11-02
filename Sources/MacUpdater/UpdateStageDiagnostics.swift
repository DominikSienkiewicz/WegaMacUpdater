import Foundation
import MacUpdaterCore

@MainActor
enum UpdateStageDiagnostics {
    static func recordOperation(_ session: UpdateOperationSession) {
        let operationID = session.operation.id.uuidString
        UpdateDiagnostics.record("operation.linked", fields: ["operationID": operationID])
        for item in session.operation.items {
            UpdateDiagnostics.record("operation.item", fields: [
                "operationID": operationID, "token": item.token, "appPath": item.appPath,
                "previousVersion": item.preUpgradeVersion ?? "unknown",
                "bundleID": item.bundleIdentifier ?? "unknown", "phase": item.phase.rawValue
            ])
        }
    }

    static func recordValidation(_ verdict: CaskValidationVerdict, token: String, operation: UpdateOperationSession?) {
        var fields = ["token": token, "verdict": String(describing: verdict)]
        if let operation { fields["operationID"] = operation.operation.id.uuidString }
        UpdateDiagnostics.record("validation.result", fields: fields)
    }

    static func recordSmoke(_ verdict: LaunchSmokeTest.Verdict, token: String) {
        var fields = ["token": token]
        switch verdict {
        case .survived: fields["verdict"] = "survived"
        case .exitedEarly(let after):
            fields["verdict"] = "exitedEarly"
            fields["afterSeconds"] = String(after)
        case .launchFailed(let message):
            fields["verdict"] = "launchFailed"
            fields["error"] = message
        case .skipped(let reason):
            fields["verdict"] = "skipped"
            fields["reason"] = String(describing: reason)
        }
        UpdateDiagnostics.record("smoke.result", fields: fields)
    }

    static func recordSummary(_ summary: UpdateRunSummary) {
        for item in summary.items {
            UpdateDiagnostics.record("update.itemVerdict", fields: [
                "key": item.key, "token": item.name, "kind": String(describing: item.kind),
                "verdict": String(describing: item.verdict)
            ])
        }
        UpdateDiagnostics.record("update.summary", fields: [
            "attempted": String(summary.attempted), "upgraded": String(summary.upgraded.count),
            "critical": String(summary.critical.count), "allItemsUpgraded": String(summary.allItemsUpgraded)
        ])
    }
}
