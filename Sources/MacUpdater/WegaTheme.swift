import AppKit
import SwiftUI

// MARK: - Appearance-adaptive palette (UX-03)

/// One brand colour, written out for every appearance macOS can resolve to.
///
/// The palette used to be a single fixed RGB triple per colour, picked against a dark
/// window. On a light desktop those same values landed at roughly 1.8–2.3:1 against the
/// background — far under the 4.5:1 WCAG asks of text — so the honey label on a white card
/// was effectively unreadable. Every entry below now carries a light and a dark value, plus
/// the pair macOS asks for when "Increase contrast" is on in System Settings › Accessibility.
///
/// The hue and saturation are the same in all four; only the brightness moves, so the light
/// appearance reads as the same colour, just deep enough to be legible.
struct WegaAdaptiveColor {
    /// A single sRGB value, written the way the palette comments always wrote it.
    struct Components: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        init(_ hex: UInt32) {
            red   = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue  = Double(hex & 0xFF) / 255
        }

        var nsColor: NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
    }

    let light: Components
    let dark: Components
    let lightIncreasedContrast: Components
    let darkIncreasedContrast: Components

    init(light: UInt32, dark: UInt32, lightIncreasedContrast: UInt32, darkIncreasedContrast: UInt32) {
        self.light = Components(light)
        self.dark = Components(dark)
        self.lightIncreasedContrast = Components(lightIncreasedContrast)
        self.darkIncreasedContrast = Components(darkIncreasedContrast)
    }

    /// The two axes the palette varies on, resolved independently.
    func components(isDark: Bool, increasedContrast: Bool) -> Components {
        switch (isDark, increasedContrast) {
        case (false, false): return light
        case (false, true):  return lightIncreasedContrast
        case (true, false):  return dark
        case (true, true):   return darkIncreasedContrast
        }
    }

    /// `bestMatch` reports only the light/dark axis — it normalizes the high-contrast
    /// appearance names back to `.aqua`/`.darkAqua` — so "Increase contrast" has to be read
    /// from the appearance's own name, with the workspace flag as the fallback for the case
    /// where AppKit hands over a plain appearance while the setting is on.
    func components(for appearance: NSAppearance) -> Components {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let increasedContrast = Self.increasedContrastAppearances.contains(appearance.name)
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return components(isDark: isDark, increasedContrast: increasedContrast)
    }

    private static let increasedContrastAppearances: Set<NSAppearance.Name> = [
        .accessibilityHighContrastAqua,
        .accessibilityHighContrastDarkAqua,
        .accessibilityHighContrastVibrantLight,
        .accessibilityHighContrastVibrantDark,
    ]

    /// A `Color` that re-resolves whenever the appearance changes, instead of baking in one
    /// of the four values at launch.
    var color: Color {
        let variants = self
        return Color(nsColor: NSColor(name: nil) { appearance in
            variants.components(for: appearance).nsColor
        })
    }
}

// MARK: - Palette

/// The brand palette, as data. The `Color` constants below are thin wrappers over these, so
/// the contrast regression test can grade the values themselves instead of trying to read
/// pixels back out of SwiftUI.
enum WegaPalette {
    // Foreground role: text, icons and hairlines drawn *on* the window background.
    //
    // Each value clears 4.5:1 twice over: against the bare window background, and against a
    // `WegaBadge` filled with 12% of the same colour, which is the least contrasty surface
    // any of these is ever asked to sit on. The increased-contrast pair clears 7:1 on both.
    static let honey = WegaAdaptiveColor(
        light: 0x806643, dark: 0xE8B87A,
        lightIncreasedContrast: 0x5C4930, darkIncreasedContrast: 0xE8B87A
    )
    static let toffee = WegaAdaptiveColor(
        light: 0x826547, dark: 0xD4A574,
        lightIncreasedContrast: 0x5D4833, darkIncreasedContrast: 0xEAB680
    )
    static let caramel = WegaAdaptiveColor(
        light: 0x905F34, dark: 0xC88549,
        lightIncreasedContrast: 0x674425, darkIncreasedContrast: 0xFBAF6B
    )
    static let lavender = WegaAdaptiveColor(
        light: 0x6E658A, dark: 0xB8A9E6,
        lightIncreasedContrast: 0x4F4862, darkIncreasedContrast: 0xC7B7F9
    )
    static let coral = WegaAdaptiveColor(
        light: 0x8C604D, dark: 0xE0997B,
        lightIncreasedContrast: 0x644537, darkIncreasedContrast: 0xFDAD8B
    )
    static let success = WegaAdaptiveColor(
        light: 0x5A7147, dark: 0x9BC47A,
        lightIncreasedContrast: 0x405132, darkIncreasedContrast: 0xA2CC7F
    )
    static let danger = WegaAdaptiveColor(
        light: 0x9C564F, dark: 0xD9786E,
        lightIncreasedContrast: 0x703E39, darkIncreasedContrast: 0xFAACA3
    )
    static let info = WegaAdaptiveColor(
        light: 0x4D6E85, dark: 0x7AB0D4,
        lightIncreasedContrast: 0x374F5F, darkIncreasedContrast: 0x8AC7F0
    )

    /// Fill role: the background of a prominent button or a filled shape whose label is
    /// `wegaInk`. It cannot follow the foreground role down into the dark end of the scale,
    /// or the dark ink on top of it would stop reading; instead the light appearance stops
    /// at the point where the fill still clears 3:1 against a white window (WCAG's bar for a
    /// non-text control) while ink still clears 4.5:1 against the fill. The
    /// increased-contrast pair matches it: with this ink there is no value that clears 4.5:1
    /// in both directions at once, and the label's legibility is the one that counts.
    static let honeyFill = WegaAdaptiveColor(
        light: 0xB28D5D, dark: 0xE8B87A,
        lightIncreasedContrast: 0xB28D5D, darkIncreasedContrast: 0xE8B87A
    )

    /// Ink drawn on top of `honeyFill`. Fixed on purpose: it is paired with the fill, not
    /// with the window background, and the fill is a light colour in every appearance.
    static let ink = WegaAdaptiveColor.Components(0x291C12)

    /// Every colour that is used as a foreground on the window background, named — the input
    /// to the contrast regression test.
    static let foregroundRoles: [(name: String, value: WegaAdaptiveColor)] = [
        ("wegaHoney", honey),
        ("wegaToffee", toffee),
        ("wegaCaramel", caramel),
        ("wegaLavender", lavender),
        ("wegaCoral", coral),
        ("wegaSuccess", success),
        ("wegaDanger", danger),
        ("wegaInfo", info),
    ]
}

extension Color {
    // Accent
    static let wegaHoney    = WegaPalette.honey.color
    static let wegaToffee   = WegaPalette.toffee.color
    static let wegaCaramel  = WegaPalette.caramel.color
    static let wegaLavender = WegaPalette.lavender.color
    static let wegaCoral    = WegaPalette.coral.color
    /// Extracted from eleven verbatim copies of the same literal.
    static let wegaInk      = Color(WegaPalette.ink.nsColor)
    // Semantic
    static let wegaSuccess  = WegaPalette.success.color
    static let wegaDanger   = WegaPalette.danger.color
    static let wegaInfo     = WegaPalette.info.color
    static let wegaHoneyFill = WegaPalette.honeyFill.color

    /// The hairline that used to be written as `Color.white.opacity(0.06)` — invisible on a
    /// light desktop, because it assumed the window behind it was dark.
    static let wegaHairline = Color(nsColor: .separatorColor)
    /// The recessed surface that used to be written as `Color.black.opacity(…)` — the same
    /// assumption, from the other side.
    static let wegaRecessedSurface = Color(nsColor: .underPageBackgroundColor)

    /// A console pane: deliberately dark in **both** appearances, the way Terminal and Xcode's
    /// console are. These are the migration log's own surfaces, extracted from the last
    /// `Color.black.opacity(…)` / `Color.white.opacity(…)` literals in the views.
    ///
    /// They are not adaptive, and that is the point — a log rendered light-on-dark in one
    /// appearance and dark-on-light in the other stops reading as a log. Keeping them here
    /// rather than at the call site means the palette still owns the value: the appearance
    /// guard can see them, and an increased-contrast variant can be given to them later
    /// without hunting through a view.
    static let wegaConsoleSurface       = Color.black.opacity(0.85)
    static let wegaConsoleHeaderSurface = Color.black.opacity(0.6)
    static let wegaConsoleInk           = Color.white.opacity(0.85)

    // Wega coat — the mascot's own drawing. A dog is the same colour on a light desktop as
    // on a dark one, so these stay fixed; they are never text, and never a control.
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

// MARK: - Typography (UX-03)

/// The app's semantic text scale.
///
/// The UI used to hard-code ~225 point sizes between 8 and 28 pt with
/// `.font(.system(size:))`, which pins text to whatever the designer's display wanted and
/// ignores the system text-size setting entirely — a user who raises it sees no change.
/// Every one of those sizes maps onto a case below, and each case resolves to the matching
/// SwiftUI text style, which does follow the system setting.
///
/// The comment on each case records the fixed size it replaced, so the visual scale stays
/// traceable to the design it came from.
enum WegaTextStyle {
    case largeTitle    // was 26–28 pt
    case title         // was 20 pt
    case title2        // was 18 pt
    case title3        // was 15–16 pt
    case headline      // was 13 pt semibold
    case body          // was 13 pt
    case callout       // was 12 pt
    case subheadline   // was 11–11.5 pt
    case footnote      // was 10–10.5 pt
    case caption       // was 9 pt
    case caption2      // was 8 pt

    var font: Font {
        switch self {
        case .largeTitle:  return .largeTitle
        case .title:       return .title
        case .title2:      return .title2
        case .title3:      return .title3
        case .headline:    return .headline
        case .body:        return .body
        case .callout:     return .callout
        case .subheadline: return .subheadline
        case .footnote:    return .footnote
        case .caption:     return .caption
        case .caption2:    return .caption2
        }
    }
}

extension Font {
    /// A style from the app's semantic scale, optionally re-weighted or monospaced.
    ///
    /// This is the single alias every call site goes through, so the scale can be retuned in
    /// one place — and so a stray `.system(size:)` stands out as the exception it now is.
    static func wega(
        _ style: WegaTextStyle,
        weight: Font.Weight? = nil,
        monospaced: Bool = false
    ) -> Font {
        var font = style.font
        if let weight { font = font.weight(weight) }
        if monospaced { font = font.monospaced() }
        return font
    }
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
        case .rollback:  return WegaState(pose: .sniff, line: tr("Coś poszło nie tak? Przyniosę starą."))
        case .uninstall: return WegaState(pose: .alert, line: tr("Aport! Zaznacz, co mam zabrać."))
        case .migration: return WegaState(pose: .idle,  line: tr("Pójdę zwęszyć /Applications."))
        case .inventory: return WegaState(pose: .idle,  line: tr("Obejdę wszystkie kąty."))
        case .logs:      return WegaState(pose: .sniff, line: tr("Co się ostatnio działo?"))
        }
    }
}

// MARK: - Layout constants
enum WegaLayout {
    static let cardRadius: CGFloat       = 12
    static let rowRadius: CGFloat        = 8
    /// Horizontal padding inside a `WegaCard` — the inset every card header and package
    /// row starts at.
    static let cardPadding: CGFloat      = 14
    /// The gutter the Updates list keeps around its cards.
    static let listGutter: CGFloat       = 16
    /// Gap between a checkbox and whatever it labels, so a group header and the rows under
    /// it put their content in the same column.
    static let checkboxSpacing: CGFloat  = 12
    /// Where the column of checkboxes on the Updates screen starts. The per-row and
    /// per-group checkboxes reach it through the card's own padding; the global
    /// "select all" control sits outside the cards and has to reproduce it, which is why
    /// the sum is written down once here instead of guessed twice.
    static let selectionColumnInset: CGFloat = listGutter + cardPadding
    static let windowMinWidth: CGFloat   = 980
    static let windowMinHeight: CGFloat  = 640
    /// UX-03 — the Settings window was pinned to exactly 640×600. At the larger system text
    /// sizes its content no longer fits in that box and had nowhere to go: the frame was
    /// fixed in both axes, so the text clipped instead of the window growing. It now opens
    /// at the same size and is free to be resized, and to grow, from there.
    static let settingsMinWidth: CGFloat     = 480
    static let settingsIdealWidth: CGFloat   = 640
    static let settingsMinHeight: CGFloat    = 400
    static let settingsIdealHeight: CGFloat  = 600
}
