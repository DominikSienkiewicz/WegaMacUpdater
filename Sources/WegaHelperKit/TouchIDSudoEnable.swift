import Foundation

/// Why the root helper would not turn Touch ID for `sudo` on. Nothing was written for any of them.
///
/// The raw values are the codes `WegaPrivilegedOps.enableTouchIDForSudoChecked` replies with: the
/// same as for turning it off, for the same conditions. −8, −9 and −11 describe removing the
/// directive and never occur here.
public enum TouchIDSudoEnableRefusal: Int, Sendable, CaseIterable {
    case noConsoleUser = -1
    case callerNotConsoleUser = -2
    case callerNotAdministrator = -3
    case notRegularFile = -4
    case unsafeOwnership = -5
    case tooLarge = -6
    case unreadable = -7
    case changedDuringOperation = -10

    /// The same condition from a gate shared with turning Touch ID off; `nil` for the three that
    /// only removing the directive has.
    init?(_ refusal: TouchIDSudoDisableRefusal) {
        self.init(rawValue: refusal.rawValue)
    }
}

/// What turning Touch ID for `sudo` on did, as the helper reports it over XPC.
public enum TouchIDSudoEnableResult: Equatable, Sendable {
    /// Written and read back.
    case enabled
    /// `sudo_local` already holds an active `pam_tid` line; nothing was written.
    case alreadyEnabled
    case refused(TouchIDSudoEnableRefusal)
    /// The write failed and the previous state is back.
    case restoredAfterFailure
    /// The write failed and could not be undone, or the file read back after it is not the one planned
    /// (Z7). `backupPath` is the copy of the previous file the writer kept; `nil` when it kept none:
    /// there was no previous file, or the readback came after the writer had removed its copy.
    case rollbackFailed(backupPath: String?)

    static let enabledCode = 1
    static let alreadyEnabledCode = 0

    /// The code on the wire: 1, 0, a refusal's raw value, −20 or −21.
    public var wireCode: Int {
        switch self {
        case .enabled: return Self.enabledCode
        case .alreadyEnabled: return Self.alreadyEnabledCode
        case .refused(let refusal): return refusal.rawValue
        case .restoredAfterFailure: return TouchIDSudoDisableResult.restoredAfterFailureCode
        case .rollbackFailed: return TouchIDSudoDisableResult.rollbackFailedCode
        }
    }

    /// The backup path that goes with −21, and nothing for any other result.
    public var wireDetail: String? {
        if case .rollbackFailed(let path) = self { return path }
        return nil
    }

    /// Decodes a reply. `nil` for an unknown code, for a detail on any code but −21, and for −21
    /// whose path is not `/etc/pam.d/.sudo_local.wega-` followed by 1–64 of `[A-Za-z0-9-]`.
    public init?(wireCode: Int, detail: String?) {
        if wireCode == TouchIDSudoDisableResult.rollbackFailedCode {
            if let detail, !TouchIDSudoDisableResult.isSwapFilePath(detail) { return nil }
            self = .rollbackFailed(backupPath: detail)
            return
        }
        guard detail == nil else { return nil }
        switch wireCode {
        case Self.enabledCode:
            self = .enabled
        case Self.alreadyEnabledCode:
            self = .alreadyEnabled
        case TouchIDSudoDisableResult.restoredAfterFailureCode:
            self = .restoredAfterFailure
        default:
            guard let refusal = TouchIDSudoEnableRefusal(rawValue: wireCode) else { return nil }
            self = .refused(refusal)
        }
    }
}

/// What `TouchIDSudoConfigurator.contentsEnablingTouchID(current:)` decided for the bytes read.
public enum TouchIDSudoEnablePlan: Equatable, Sendable {
    /// An active `pam_tid` line is there already.
    case alreadyEnabled
    /// Only `.unreadable` (not UTF-8, or a NUL) or `.tooLarge` (the result would pass the limit).
    case refused(TouchIDSudoEnableRefusal)
    /// Write `contents`: the bytes read, a newline if the last line had none, then the directive.
    case write(Data)
}

/// The step of the enable operation a report names, for the helper's audit log.
public enum TouchIDSudoEnableStep: String, Sendable {
    case caller, directory, read, template, plan, write, verify
}

/// What the helper logs about one enable call besides its result. It holds no byte of the file.
public struct TouchIDSudoEnableReport: Equatable, Sendable {
    public var result: TouchIDSudoEnableResult
    /// The step that decided a result other than success.
    public var failedStep: TouchIDSudoEnableStep?

    public init(result: TouchIDSudoEnableResult, failedStep: TouchIDSudoEnableStep? = nil) {
        self.result = result
        self.failedStep = failedStep
    }
}
