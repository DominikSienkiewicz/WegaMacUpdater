import Foundation

/// Overall trust verdict for the inspector's Trust panel.
/// `.unavailable` means we have nothing to verify (e.g. a formula or npm package
/// — no app bundle), `.warning` means at least one signal is a red flag, `.ok` otherwise.
public enum TrustLevel: Equatable, Sendable {
    case ok, warning, unavailable
}

/// Combines the signing signals for a selected update into one verdict.
/// - `audit`: Team ID audit vs the ledger, or nil if no bundle to inspect.
/// - `signatureValid`: whether the code signature checked out, or nil if not checked / no bundle.
/// - `caskChecksumPresent`: whether a cask download has a real checksum, or nil if not a cask.
/// A changed publisher (Team ID), an invalid signature, or a missing cask checksum is a warning.
public func trustLevel(audit: TeamIDAudit?,
                       signatureValid: Bool?,
                       caskChecksumPresent: Bool?) -> TrustLevel {
    if audit == nil && signatureValid == nil && caskChecksumPresent == nil { return .unavailable }
    if case .changed = audit { return .warning }
    if signatureValid == false { return .warning }
    if caskChecksumPresent == false { return .warning }
    return .ok
}
