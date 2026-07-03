import Foundation

/// The cask token whose Homebrew download checksum applies to this update, or nil when the
/// checksum signal doesn't apply. Only a plain `.cask` source is backed by `caskDownloads`;
/// other cask-adjacent sources (jetbrains, self-updating apps) are surfaced by different checkers
/// and have no checksum entry, so returning nil keeps the Trust panel from showing a false "absent"
/// (I-4).
public func caskChecksumToken(of source: ManualOutdatedApp.UpdateSource) -> String? {
    if case .cask(let token) = source { return token }
    return nil
}
