import Foundation

/// Why the root helper would not turn Touch ID for `sudo` off. Nothing was written for any of them
/// except −10, which can follow the swap: the previous file may then be left under the swap name.
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
    /// `sudo_local` changed while the helper was working on it. This can follow the swap; the
    /// helper never swaps back over another writer's file, so the previous file may then be left
    /// under the swap name.
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
    /// Nothing was written, except that −10 can follow a swap and leave the previous file under
    /// the swap name.
    case refused(TouchIDSudoDisableRefusal)
    /// A step failed and `sudo_local` is the original file again; nothing changed.
    case restoredAfterFailure
    /// Swapping the original back failed; `backupPath` names the file that was in `sudo_local`
    /// right before the helper swapped it out.
    case rollbackFailed(backupPath: String)

    static let restoredAfterFailureCode = -20
    static let rollbackFailedCode = -21

    /// The code on the wire: the number of removed lines, 0, a refusal's raw value, −20 or −21.
    public var wireCode: Int {
        switch self {
        case .removed(let lines): return lines
        case .nothingToRemove: return 0
        case .refused(let refusal): return refusal.rawValue
        case .restoredAfterFailure: return Self.restoredAfterFailureCode
        case .rollbackFailed: return Self.rollbackFailedCode
        }
    }

    /// The path that goes with −21, and nothing for any other result.
    public var wireDetail: String? {
        if case .rollbackFailed(let path) = self { return path }
        return nil
    }

    /// Decodes a reply. `nil` for an unknown code, and for −21 whose path is not
    /// `/etc/pam.d/.sudo_local.wega-` followed by 1–64 of `[A-Za-z0-9-]`, so the app never shows a
    /// path outside the policy directory.
    public init?(wireCode: Int, detail: String?) {
        switch wireCode {
        case 1...:
            self = .removed(lines: wireCode)
        case 0:
            self = .nothingToRemove
        case Self.restoredAfterFailureCode:
            self = .restoredAfterFailure
        case Self.rollbackFailedCode:
            guard let detail, Self.isSwapFilePath(detail) else { return nil }
            self = .rollbackFailed(backupPath: detail)
        default:
            guard let refusal = TouchIDSudoDisableRefusal(rawValue: wireCode) else { return nil }
            self = .refused(refusal)
        }
    }

    /// Compared as UTF-8 bytes, so no combining mark can make another path read as this one.
    private static func isSwapFilePath(_ path: String) -> Bool {
        let prefix = TouchIDSudoDisabler.reportedPath(of: TouchIDSudoDisabler.swapNamePrefix).utf8
        guard path.utf8.starts(with: prefix) else { return false }
        let name = path.utf8.dropFirst(prefix.count)
        return (1...64).contains(name.count) && name.allSatisfy(isSwapNameByte)
    }

    private static func isSwapNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"):
            return true
        default:
            return false
        }
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

    /// Whether `leftBehindPath` holds the file that was in `sudo_local` before the swap rather
    /// than the helper's own new file: after a removal whose cleanup failed, and after a swap back
    /// the helper refused because `sudo_local` no longer held its new file.
    public var leftBehindIsPreviousFile: Bool {
        if case .removed = result { return true }
        return result == .refused(.changedDuringOperation) && failedStep == .swapBack
    }
}

extension TouchIDSudoConfigurator {
    /// Removes every line that is byte for byte the exact directive, and only when everything else
    /// in the file is a blank line or a full comment. Pure; the root helper and the tests call it.
    ///
    /// Decided on bytes, not `String`: `"\r\n"` is one `Character`, so a split on `"\n"` would not
    /// see it, and `String` equality applies canonical equivalence. In order: too large, not UTF-8 or
    /// a NUL, no exact directive, a backslash anywhere (OpenPAM joins a line ending in one to the
    /// next, and with one anywhere it is not certain where a line ends), any other active line.
    public static func contentsDisablingTouchID(current: Data) -> TouchIDSudoDisablePlan {
        guard current.count <= TouchIDSudoDisabler.maximumSize else { return .refused(.tooLarge) }
        let bytes = [UInt8](current)
        guard !bytes.contains(0), String(validating: bytes, as: UTF8.self) != nil else { return .refused(.unreadable) }
        let lines = PAMPolicyLines.physicalLines(bytes)
        let kept = lines.filter { !PAMPolicyLines.isExactDirective($0) }
        let removed = lines.count - kept.count
        guard removed > 0 else { return .nothingToRemove }
        guard !bytes.contains(PAMPolicyLines.backslash) else { return .refused(.lineContinuation) }
        guard kept.allSatisfy({ PAMPolicyLines.isBlankOrComment(PAMPolicyLines.content(of: $0)) }) else {
            return .refused(.otherDirectivesPresent)
        }
        return .remove(lines: removed, contents: Data(kept.joined()))
    }
}

/// A PAM policy file read the way OpenPAM reads it: physical lines end at `0x0A` only.
enum PAMPolicyLines {
    static let newline = UInt8(ascii: "\n")
    static let backslash = UInt8(ascii: "\\")
    private static let commentMark = UInt8(ascii: "#")
    /// SP, HT, VT, FF and CR, skipped before deciding whether a line is blank or a comment.
    private static let leadingBlanks: Set<UInt8> = [0x20, 0x09, 0x0B, 0x0C, 0x0D]
    private static let directive = Array(TouchIDSudoConfigurator.pamDirective.utf8)

    /// Each line with its newline, if it has one; the empty tail after a final newline is no line.
    static func physicalLines(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var lines: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: newline).map { $0 + 1 } ?? bytes.endIndex
            lines.append(bytes[start..<end])
            start = end
        }
        return lines
    }

    /// A plain split, kept apart from `physicalLines` so that a readback is checked by a second,
    /// independent reading of the same bytes.
    static func referenceLines(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var lines = bytes.split(separator: newline, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    static func content(of line: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        line.last == newline ? line.dropLast() : line
    }

    static func isExactDirective(_ line: ArraySlice<UInt8>) -> Bool {
        content(of: line).elementsEqual(directive)
    }

    static func isBlankOrComment(_ content: ArraySlice<UInt8>) -> Bool {
        guard let first = content.first(where: { !leadingBlanks.contains($0) }) else { return true }
        return first == commentMark
    }
}
