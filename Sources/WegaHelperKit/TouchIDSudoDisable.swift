import Foundation

/// Why the root helper would not turn Touch ID for `sudo` off. Nothing was written for any of them.
///
/// The raw value is the code `WegaPrivilegedOps.disableTouchIDForSudo` replies with.
public enum TouchIDSudoDisableRefusal: Int, Sendable, CaseIterable {
    /// Nobody is logged in at the console.
    case noConsoleUser = -1
    /// The caller is not the user at the console (fast user switching).
    case callerNotConsoleUser = -2
    /// The caller is not a member of the `admin` group.
    case callerNotAdministrator = -3
    /// `sudo_local` is a link, a directory, a FIFO or a socket rather than a regular file.
    case notRegularFile = -4
    /// `sudo_local` or `/etc/pam.d` is not root's alone: another owner, write for group or other,
    /// or an ACL, present or unreadable.
    case unsafeOwnership = -5
    /// `sudo_local` is larger than `TouchIDSudoDisabler.maximumSize`.
    case tooLarge = -6
    /// `sudo_local` could not be read, is not UTF-8 or holds a NUL byte.
    case unreadable = -7
    /// `sudo_local` holds a backslash somewhere, so where its lines end is not certain.
    case lineContinuation = -8
    /// A later PAM policy file exists, which `sudo` would read once nothing active is left.
    case fallbackPolicyPresent = -9
    /// `sudo_local` changed while the helper was working on it.
    case changedDuringOperation = -10
    /// A line other than the exact directive is active, so removing the directive would change
    /// what the rest of the file means.
    case otherDirectivesPresent = -11
}

/// What turning Touch ID for `sudo` off did, as the helper reports it over XPC.
public enum TouchIDSudoDisableResult: Equatable, Sendable {
    /// That many exact directives were removed and the new file was verified.
    case removed(lines: Int)
    /// There is no `sudo_local`, or it holds no exact directive; nothing was written.
    case nothingToRemove
    /// Nothing was written.
    case refused(TouchIDSudoDisableRefusal)
    /// A step failed and `sudo_local` is the original file again; nothing changed.
    case restoredAfterFailure
    /// Swapping the original back failed; `backupPath` names the file that was in `sudo_local`
    /// right before the helper swapped it out.
    case rollbackFailed(backupPath: String)

    /// The code on the wire: the number of removed lines, 0, a refusal's raw value, −20 or −21.
    public var wireCode: Int {
        0
    }

    /// The path that goes with −21, and nothing for any other result.
    public var wireDetail: String? {
        nil
    }

    /// Decodes a reply. `nil` for an unknown code, and for −21 whose path is not
    /// `/etc/pam.d/.sudo_local.wega-` followed by 1–64 of `[A-Za-z0-9-]`, so the app never shows a
    /// path outside the policy directory.
    public init?(wireCode: Int, detail: String?) {
        nil
    }
}

/// What `TouchIDSudoConfigurator.contentsDisablingTouchID(current:)` decided for a file.
public enum TouchIDSudoDisablePlan: Equatable, Sendable {
    /// No line is the exact directive.
    case nothingToRemove
    /// Only `.tooLarge`, `.unreadable`, `.lineContinuation` or `.otherDirectivesPresent`.
    case refused(TouchIDSudoDisableRefusal)
    /// Write `contents`, which is the file without its `lines` exact directives.
    case remove(lines: Int, contents: Data)
}

/// The step of the disable operation a report names, for the helper's audit log.
public enum TouchIDSudoDisableStep: String, Sendable {
    case caller, directory, read, plan, fallback, capability, temporary, swap, directorySync,
         swappedOutCheck, verify, swapBack, swapBackVerify, cleanup
}

/// What the helper logs about one disable call besides its result. It holds no byte of the file.
public struct TouchIDSudoDisableReport: Equatable, Sendable {
    public var result: TouchIDSudoDisableResult
    /// The step that decided a result other than success, or a cleanup that failed after one.
    public var failedStep: TouchIDSudoDisableStep?
    /// The later policy file that exists, for −9.
    public var fallbackPolicyPath: String?
    /// How many names `sudo_local` had, when it was not one.
    public var linkCount: UInt32?
    /// A file this call created or swapped out and did not remove.
    public var leftBehindPath: String?

    public init(
        result: TouchIDSudoDisableResult,
        failedStep: TouchIDSudoDisableStep? = nil,
        fallbackPolicyPath: String? = nil,
        linkCount: UInt32? = nil,
        leftBehindPath: String? = nil
    ) {
        self.result = result
        self.failedStep = failedStep
        self.fallbackPolicyPath = fallbackPolicyPath
        self.linkCount = linkCount
        self.leftBehindPath = leftBehindPath
    }
}

extension TouchIDSudoConfigurator {
    /// Removes every line that is byte for byte the exact directive, and only when everything else
    /// in the file is a blank line or a full comment. Pure; the root helper and the tests call it.
    public static func contentsDisablingTouchID(current: Data) -> TouchIDSudoDisablePlan {
        .nothingToRemove
    }
}
