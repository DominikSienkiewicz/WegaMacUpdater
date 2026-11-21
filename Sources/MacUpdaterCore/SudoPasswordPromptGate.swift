import Foundation
import WegaHelperKit

/// Why the Touch ID card offers no `sudo` route, only recoveryOS advice, and, by the owner's
/// decision of 2026-11-21 (Z12), why Wega asks for no administrator password itself: `sudo` reads
/// these settings before it asks for anything, so a module someone added there could keep it.
public enum SudoPolicyDistrust: Equatable, Sendable {
    /// −4 or −5, as the app saw it or a helper call reported it.
    case unsafePolicy(TouchIDSudoDisableRefusal)
    /// The app saw that someone other than root can change `/etc/pam.d/sudo`.
    case unsafeSudoFile
    /// The app could not establish that the settings are root's alone; treated like −5.
    case noProofOfSafety

    /// For diagnostics and the log: the reason's name, never a path or a byte of a file.
    public var logName: String {
        switch self {
        case .unsafePolicy(let refusal): return "unsafePolicy(\(refusal.rawValue))"
        case .unsafeSudoFile:            return "unsafeSudoFile"
        case .noProofOfSafety:           return "noProofOfSafety"
        }
    }
}

extension TouchIDDisablePreflight {
    /// The card's rule, in one place: what was seen comes before what could not be established.
    public func recoveryOnlyReason(helperReported: TouchIDSudoDisableRefusal?) -> SudoPolicyDistrust? {
        if let refusal = refusal ?? helperReported { return .unsafePolicy(refusal) }
        if sudoPolicyIsUnsafe { return .unsafeSudoFile }
        return commandsAreSafe ? nil : .noProofOfSafety
    }
}

/// One answer for every route on which Wega could ask for the administrator password: the window's
/// update run, the brew environment, `mas`'s `sudo -v`, the askpass and the sudo shim.
public final class SudoPasswordPromptGate: @unchecked Sendable {
    /// The app's gate. The Touch ID card records what it reads here, and the run asks it.
    public static let shared = SudoPasswordPromptGate()

    private let lock = NSLock()
    private let readPreflight: @Sendable () -> TouchIDDisablePreflight
    private var lastPreflight: TouchIDDisablePreflight?
    private var helperReported: TouchIDSudoDisableRefusal?

    public init(readPreflight: @escaping @Sendable () -> TouchIDDisablePreflight = { TouchIDDisablePreflight.live() }) {
        self.readPreflight = readPreflight
    }

    /// Reads the settings now; the answer stands until the next read.
    @discardableResult
    public func check() -> SudoPolicyDistrust? {
        record(readPreflight())
    }

    /// Keeps a preflight the Touch ID card has just read, so the card and the prompts never disagree.
    @discardableResult
    public func record(_ preflight: TouchIDDisablePreflight) -> SudoPolicyDistrust? {
        lock.withLock {
            lastPreflight = preflight
            return preflight.recoveryOnlyReason(helperReported: helperReported)
        }
    }

    /// −4 or −5 a helper call reported. Root may see what the app cannot, so it holds until a helper
    /// call succeeds, which sets `nil` (RC2-7).
    public var helperReportedUnsafePolicy: TouchIDSudoDisableRefusal? {
        get { lock.withLock { helperReported } }
        set { lock.withLock { helperReported = newValue } }
    }

    /// The last answer, without reading again; the first question reads.
    public var reason: SudoPolicyDistrust? {
        let known: SudoPolicyDistrust?? = lock.withLock {
            lastPreflight.map { $0.recoveryOnlyReason(helperReported: helperReported) }
        }
        return known ?? check()
    }

    public var allowsPasswordPrompts: Bool { reason == nil }

    /// For a process of its own (the askpass, the sudo shim), which cannot hear what a helper told
    /// the app: it reads the settings itself.
    public static func liveReason() -> SudoPolicyDistrust? {
        TouchIDDisablePreflight.live().recoveryOnlyReason(helperReported: nil)
    }
}
