import Foundation
import MacUpdaterCore

@testable import WegaMacUpdater

final class ScanStoreRuntimeDownloadGateDefaults {
    private let defaults: UserDefaults
    private let previousValues: [String: Any]
    private let missingKeys: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let values: [String: Any] = [
            DownloadGate.Configuration.largeDownloadThresholdMBKey: 1,
            DownloadGate.Configuration.lowBatteryThresholdPercentKey: 1,
            DownloadGate.Configuration.unpackedSizeMultiplierKey: 0.5,
            DownloadGate.Configuration.safetyMarginGBKey: 0,
        ]
        var previousValues: [String: Any] = [:]
        var missingKeys: Set<String> = []
        for key in values.keys {
            if let value = defaults.object(forKey: key) {
                previousValues[key] = value
            } else {
                missingKeys.insert(key)
            }
        }
        self.previousValues = previousValues
        self.missingKeys = missingKeys
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
    }

    func restore() {
        for key in missingKeys {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in previousValues {
            defaults.set(value, forKey: key)
        }
    }
}

func makeScanStoreRuntimeTemporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeScanStoreRuntimeApp(
    at url: URL,
    bundleIdentifier: String,
    version: String,
    payload: String
) throws {
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleShortVersionString": version,
    ]
    try PropertyListSerialization.data(
        fromPropertyList: plist,
        format: .xml,
        options: 0
    ).write(to: contents.appendingPathComponent("Info.plist"))
    try Data(payload.utf8).write(to: contents.appendingPathComponent("payload"))
}

@MainActor
func makeScanStoreRuntimeUndoOperation(
    token: String,
    appURL: URL,
    copySnapshot: Bool
) throws -> (undoable: UndoableUpdate, operationID: UUID) {
    let operation = UpdateOperationStore.shared.begin(trigger: .manual)
    operation.recordPlanned(tokens: [token], appPaths: [token: appURL])
    let snapshotName = UpdateOperationSession.snapshotDirectoryName(for: token)
    if copySnapshot {
        try BundleSnapshot.clone(
            appURL,
            to: UpdateOperationStore.shared.snapshotURL(
                operationID: operation.operation.id,
                name: snapshotName
            )
        )
    }
    operation.recordSnapshotted(token: token, snapshotName: snapshotName)
    operation.recordInstalling()
    operation.recordVerdict(token: token, verdict: .healthy)

    let item = operation.operation.items[0]
    return (
        UndoableUpdate(
            operationID: operation.operation.id,
            token: token,
            appPath: appURL.path,
            restoredVersion: item.preUpgradeVersion,
            updatedAt: Date(),
            expiresAt: Date().addingTimeInterval(UpdateOperationStore.retentionInterval)
        ),
        operation.operation.id
    )
}

@MainActor
func removeScanStoreRuntimeOperations(createdAfter baseline: Set<UUID>) {
    let current = Set(UpdateOperationStore.shared.operations().map(\.id))
    for operationID in current.subtracting(baseline) {
        UpdateOperationStore.shared.removeOperation(id: operationID)
    }
}
