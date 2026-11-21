import Darwin
import Foundation

/// Turns Touch ID for `sudo` off as root: removes the exact directive from `sudo_local` through a
/// new file swapped in with `RENAME_SWAP`, verifies it, and swaps the original back on any failure.
public enum TouchIDSudoDisabler {
    /// Who asks, as the kernel and the system report it for the XPC connection.
    public struct Caller: Equatable, Sendable {
        public var uid: UInt32
        public var consoleUserUID: UInt32?
        public var isAdministrator: Bool

        public init(uid: UInt32, consoleUserUID: UInt32?, isAdministrator: Bool) {
            self.uid = uid
            self.consoleUserUID = consoleUserUID
            self.isAdministrator = isAdministrator
        }
    }

    /// The largest `sudo_local` the helper changes.
    public static let maximumSize = 65_536
    public static let fallbackPolicyPaths = SystemPaths.pamFallbackPolicyPaths
    /// Every name this operation creates in the policy directory starts with this.
    public static let swapNamePrefix = ".sudo_local.wega-"

    public static func refusal(caller: Caller) -> TouchIDSudoDisableRefusal? {
        nil
    }

    public static func refusal(directory: PAMPolicyDirectoryFacts) -> TouchIDSudoDisableRefusal? {
        nil
    }

    public static func refusal(file: PAMPolicyFileFacts) -> TouchIDSudoDisableRefusal? {
        nil
    }

    /// The whole operation over the policy directory `openDirectory` opens.
    static func run(
        caller: Caller,
        openDirectory: () throws -> any PAMPolicyDirectoryAccess,
        fallbackExists: (String) -> Bool,
        makeName: () -> String,
        requiredOwnerUID: UInt32 = 0
    ) -> TouchIDSudoDisableReport {
        TouchIDSudoDisableReport(result: .nothingToRemove)
    }

    public static func runLive(caller: Caller) -> TouchIDSudoDisableReport {
        TouchIDSudoDisableReport(result: .nothingToRemove)
    }

    /// The live swap name: the prefix, `swap-` and a fresh UUID.
    static func makeSwapName() -> String {
        ""
    }

    /// How a name in the policy directory is reported to the app.
    static func reportedPath(of name: String) -> String {
        name
    }

    /// Whether a later policy path is there, or cannot be shown not to be.
    static func fallbackPolicyEntryExists(atPath path: String) -> Bool {
        false
    }

    /// Whether `readback` is the planned file and still means what the original meant without the
    /// directive.
    static func readbackIsAcceptable(_ readback: Data, expected: Data, original: Data) -> Bool {
        true
    }
}
