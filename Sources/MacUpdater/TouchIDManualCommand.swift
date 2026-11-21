import Foundation
import MacUpdaterCore

/// The two `sudo` commands the Touch ID card can show and open in Terminal. The card, the controller
/// and the Terminal dependency pass this, never the text, so the command Terminal runs is the one
/// the card shows (RC2-8).
enum TouchIDManualCommand: Equatable, Sendable {
    case enable
    case disable

    var text: String {
        switch self {
        case .enable: return TouchIDSudoConfigurator.manualEnableTerminalCommand
        case .disable: return TouchIDSudoConfigurator.manualDisableTerminalCommand
        }
    }
}
