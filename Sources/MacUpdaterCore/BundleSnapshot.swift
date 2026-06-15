import Foundation
import Darwin

/// Per-app rollback via APFS copy-on-write clones (**FEAT-05 / Prop#2-alt**).
///
/// This is the realistic alternative to the (blocked) APFS *snapshot revert* —
/// `com.apple.private.apfs.revert-to-snapshot` is an Apple-only SPI. `clonefile(2)`
/// needs **no entitlement**, is instant, and shares blocks until one side changes.
/// Strategy: clone the `.app` before an upgrade; if the upgrade is bad, restore
/// the clone with an atomic replace. No competitor offers "undo this app update".
public enum BundleSnapshot {
    public enum SnapshotError: Error, LocalizedError {
        case cloneFailed(errno: Int32)
        case restoreFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cloneFailed(let code):
                return "clonefile nie powiódł się (errno \(code)). Wolumin musi być APFS, a cel nie może istnieć."
            case .restoreFailed(let message):
                return "Przywracanie z klona nie powiodło się: \(message)"
            }
        }
    }

    /// Instant COW clone of `source` → `destination` (same APFS volume; destination
    /// must not pre-exist — we remove it first). No special entitlement required.
    public static func clone(_ source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let rc = source.withUnsafeFileSystemRepresentation { srcPtr -> Int32 in
            guard let srcPtr else { return -1 }
            return destination.withUnsafeFileSystemRepresentation { dstPtr -> Int32 in
                guard let dstPtr else { return -1 }
                return clonefile(srcPtr, dstPtr, 0)
            }
        }
        if rc != 0 { throw SnapshotError.cloneFailed(errno: errno) }
    }

    /// Atomically swap `target` (e.g. a bad upgrade) back to `snapshot`. Consumes
    /// the snapshot (moved into place) on success.
    public static func restore(snapshot: URL, to target: URL) throws {
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: snapshot)
        } catch {
            throw SnapshotError.restoreFailed(error.localizedDescription)
        }
    }
}

/// Post-upgrade health gate (**FEAT-05 / I-3 canary**). The Gatekeeper verdict is
/// a pure, side-effect-free check usable from Core; the "launch and confirm it
/// stays alive N seconds" step is left to the UI/orchestration layer (it actually
/// launches the app) and should call `BundleSnapshot.restore` on failure.
public enum CanaryCheck {
    /// True when Gatekeeper would approve launching the freshly-upgraded app.
    public static func passesGatekeeper(appAt url: URL) -> Bool {
        CodeSignatureVerifier.passesGatekeeperForExecution(at: url)
    }
}
