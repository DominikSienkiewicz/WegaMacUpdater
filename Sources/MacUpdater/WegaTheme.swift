import SwiftUI

// MARK: - Palette
extension Color {
    // Accent
    static let wegaHoney   = Color(red: 0.910, green: 0.722, blue: 0.478) // #e8b87a
    static let wegaToffee  = Color(red: 0.831, green: 0.647, blue: 0.455) // #d4a574
    static let wegaCaramel = Color(red: 0.690, green: 0.459, blue: 0.251) // #b07540
    // Semantic
    static let wegaSuccess = Color(red: 0.608, green: 0.769, blue: 0.478) // #9bc47a
    static let wegaDanger  = Color(red: 0.831, green: 0.459, blue: 0.420) // #d4756b
    static let wegaInfo    = Color(red: 0.478, green: 0.690, blue: 0.831) // #7ab0d4
    // Wega coat
    static let wegaBodyTan   = Color(red: 0.831, green: 0.627, blue: 0.416) // #d4a06a
    static let wegaBodyShade = Color(red: 0.659, green: 0.459, blue: 0.267) // #a87544
    static let wegaEarDark   = Color(red: 0.227, green: 0.157, blue: 0.094) // #3a2818
    static let wegaEarInner  = Color(red: 0.784, green: 0.522, blue: 0.478) // #c8857a
    static let wegaMuzzle    = Color(red: 0.478, green: 0.310, blue: 0.180) // #7a4f2e
    static let wegaChest     = Color(red: 0.953, green: 0.890, blue: 0.784) // #f3e3c8
    static let wegaFeature   = Color(red: 0.055, green: 0.031, blue: 0.020) // #0e0805
    static let wegaCollar    = Color(red: 0.776, green: 0.376, blue: 0.333) // #c66055
    static let wegaTongue    = Color(red: 0.910, green: 0.565, blue: 0.565) // #e89090
}

// MARK: - Pose
enum WegaPose: Equatable {
    case idle, sniff, alert, happy, sad, sleep
}

// MARK: - Sidebar Wega prominence
enum WegaProminence {
    case subtle, friendly, hero
}

// MARK: - Wega state (pose + speech line)
struct WegaState: Equatable {
    var pose: WegaPose
    var line: String

    static let initial = WegaState(pose: .idle, line: tr("Cześć! Co dziś robimy?"))

    static func forTab(_ tab: SidebarTab) -> WegaState {
        switch tab {
        case .update:    return WegaState(pose: .idle,  line: tr("Sprawdzimy, co się zestarzało?"))
        case .uninstall: return WegaState(pose: .alert, line: tr("Aport! Zaznacz, co mam zabrać."))
        case .migration: return WegaState(pose: .idle,  line: tr("Pójdę zwęszyć /Applications."))
        case .inventory: return WegaState(pose: .idle,  line: tr("Obejdę wszystkie kąty."))
        case .info:      return WegaState(pose: .idle, line: tr("Oto co o sobie wiem."))
        }
    }
}

// MARK: - Layout constants
enum WegaLayout {
    static let sidebarWidth: CGFloat     = 240
    static let cardRadius: CGFloat       = 12
    static let rowRadius: CGFloat        = 8
    static let windowMinWidth: CGFloat   = 980
    static let windowMinHeight: CGFloat  = 640
}
