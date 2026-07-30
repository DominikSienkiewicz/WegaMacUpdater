import AppKit
import SwiftUI
import Testing

@testable import WegaMacUpdater

// UX-03 — the three things that made the interface stop working outside its original
// conditions: text pinned to fixed point sizes, a palette tuned for one appearance, and
// animations that never end.
//
// The palette suite grades the values themselves rather than screenshots: WCAG contrast is
// arithmetic on sRGB components, and the components are the thing a future edit would get
// wrong. What arithmetic cannot answer — how the result actually looks with VoiceOver, at
// the largest system text sizes, or under "Increase contrast" — is the runtime check the
// card asks for separately.

// MARK: - Typography

@Suite("UX-03 — semantic text scale")
struct SemanticTypographyTests {
    /// A hard-coded size is allowed only where the text is a drawing sized by its own
    /// container, and only when it says so on the spot.
    static let exemptionMarker = "UX-03-fixed-size:"

    /// The two drawings that legitimately keep a fixed size. Listed by name so adding a
    /// third is a deliberate edit to this test rather than a quiet regression.
    static let filesAllowedFixedSizes: Set<String> = [
        "BinaryStream.swift",
        "SharedViews.swift",
    ]

    /// What the guard is allowed to miss.
    ///
    /// It used to be a non-recursive `contentsOfDirectory` on `Sources/MacUpdater`: it swept in
    /// 32 files there that build no views at all, and could not see a new subdirectory under
    /// that path or a second target that imports SwiftUI. The scope is now the import, not the
    /// directory — so a file gains SwiftUI and gains the guard in the same edit, wherever it
    /// lives.
    ///
    /// Red before the fix: the directory scan returned every `.swift` in that one folder,
    /// including the 32 without `import SwiftUI`.
    @Test("The typography guard scans by import, across every module")
    func theGuardFollowsSwiftUIRatherThanADirectory() throws {
        let scanned = try UX03Sources.appViewFiles()

        #expect(!scanned.isEmpty, "sanity: the scan found the views")

        let withoutSwiftUI = try scanned.filter {
            try !String(contentsOf: $0, encoding: .utf8).contains("import SwiftUI")
        }
        #expect(withoutSwiftUI.isEmpty,
                """
                UX-03: the guard is scanning files that build no views — \
                \(withoutSwiftUI.map(\.lastPathComponent).joined(separator: ", ")). \
                That is a directory scan wearing the shape of a rule.
                """)

        // The other direction: nothing that does build views may sit outside the net.
        var expected: Set<String> = []
        let enumerator = FileManager.default.enumerator(
            at: UX03Sources.sourcesRoot, includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            if try String(contentsOf: url, encoding: .utf8).contains("import SwiftUI") {
                expected.insert(url.lastPathComponent)
            }
        }
        #expect(Set(scanned.map(\.lastPathComponent)) == expected,
                "UX-03: every SwiftUI file under Sources/ is covered, whichever module it is in")
    }

    @Test("No view hard-codes a point size without a justification on the spot")
    func everySizeComesFromTheSemanticScale() throws {
        var offenders: [String] = []

        for file in try UX03Sources.appViewFiles() {
            let lines = try UX03Sources.lines(of: file)
            for (index, line) in lines.enumerated() {
                guard line.contains(".system(size:") else { continue }
                guard !UX03Sources.isComment(line) else { continue }

                let justification = lines[max(0, index - 3)...index]
                let isJustified = justification.contains { $0.contains(Self.exemptionMarker) }
                    && Self.filesAllowedFixedSizes.contains(file.lastPathComponent)
                if !isJustified {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            These call sites pin text to a fixed point size, so it cannot follow the system \
            text-size setting. Use Font.wega(_:weight:monospaced:), or mark the line with \
            "\(Self.exemptionMarker)" and a reason if it is a drawing rather than text: \
            \(offenders.joined(separator: ", "))
            """
        )
    }

    @Test("Every exemption that exists is one this test knows about")
    func theExemptionListIsExhaustive() throws {
        var marked: Set<String> = []
        for file in try UX03Sources.appViewFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(Self.exemptionMarker) {
                marked.insert(file.lastPathComponent)
            }
        }

        #expect(marked == Self.filesAllowedFixedSizes)
    }

    /// The point of the alias: what comes out is a *text style*, which macOS resizes with
    /// the system setting, and never a fixed size, which it does not.
    @Test("The alias resolves to text styles, never to a fixed size")
    func aliasResolvesToTextStyles() {
        #expect(Font.wega(.largeTitle) == .largeTitle)
        #expect(Font.wega(.title) == .title)
        #expect(Font.wega(.title2) == .title2)
        #expect(Font.wega(.title3) == .title3)
        #expect(Font.wega(.headline) == .headline)
        #expect(Font.wega(.body) == .body)
        #expect(Font.wega(.callout) == .callout)
        #expect(Font.wega(.subheadline) == .subheadline)
        #expect(Font.wega(.footnote) == .footnote)
        #expect(Font.wega(.caption) == .caption)
        #expect(Font.wega(.caption2) == .caption2)

        #expect(Font.wega(.body) != .system(size: 13))
        #expect(Font.wega(.callout) != .system(size: 12))
        #expect(Font.wega(.subheadline) != .system(size: 11))
    }

    @Test("Weight and monospacing modify the style instead of replacing it")
    func modifiersStayOnTopOfTheStyle() {
        #expect(Font.wega(.callout, weight: .medium) == Font.callout.weight(.medium))
        #expect(Font.wega(.subheadline, monospaced: true) == Font.subheadline.monospaced())
        #expect(
            Font.wega(.footnote, weight: .semibold, monospaced: true)
                == Font.footnote.weight(.semibold).monospaced()
        )
        #expect(Font.wega(.callout, weight: .medium) != Font.wega(.callout))
    }

    /// A view that inherits the environment font still grows with it — the lever macOS
    /// actually exposes to a headless test. QA-02 pinned this for `PackageRow`; the semantic
    /// scale must not have quietly frozen the rest of the chrome at a fixed height.
    @Test @MainActor
    func cardHeadersReflowWithLargerText() {
        let header = { (font: Font) in
            NSHostingView(
                rootView: WegaCardHeader(
                    icon: "shippingbox",
                    title: "Nagłówek karty",
                    count: 3,
                    caption: "Druga linia, która musi się zawinąć przy dużym tekście."
                )
                .environment(\.font, font)
                .frame(width: 380)
            ).fittingSize.height
        }

        #expect(header(.system(size: 32)) > header(.body))
    }
}

// MARK: - Palette

@Suite("UX-03 — appearance-adaptive palette")
struct AdaptivePaletteTests {
    /// `NSColor.windowBackgroundColor` resolves to pure white in both light appearances and
    /// to #1E1E1E in both dark ones, so these are the surfaces every brand colour is read
    /// against — and the strictest ones available.
    static let lightBackground = WegaAdaptiveColor.Components(0xFFFFFF).wcag
    static let darkBackground = WegaAdaptiveColor.Components(0x1E1E1E).wcag

    /// WCAG AA for body text, and AAA for the pair macOS hands out when the user has asked
    /// for increased contrast.
    static let normalMinimum = 4.5
    static let increasedMinimum = 7.0

    @Test(
        "Foreground colours clear WCAG AA on the window background",
        arguments: WegaPalette.foregroundRoles.map(\.name)
    )
    func foregroundColoursClearAAOnTheWindow(name: String) throws {
        let entry = try #require(WegaPalette.foregroundRoles.first { $0.name == name }?.value)

        #expect(entry.light.wcag.contrast(against: Self.lightBackground) >= Self.normalMinimum)
        #expect(entry.dark.wcag.contrast(against: Self.darkBackground) >= Self.normalMinimum)
        #expect(
            entry.lightIncreasedContrast.wcag.contrast(against: Self.lightBackground)
                >= Self.increasedMinimum
        )
        #expect(
            entry.darkIncreasedContrast.wcag.contrast(against: Self.darkBackground)
                >= Self.increasedMinimum
        )
    }

    /// The least contrasty surface any brand colour sits on is a `WegaBadge`, which fills
    /// its background with 12% of the same colour. Clearing the bare window is not enough.
    @Test(
        "Foreground colours clear WCAG AA on their own badge tint",
        arguments: WegaPalette.foregroundRoles.map(\.name)
    )
    func foregroundColoursClearAAOnTheirBadge(name: String) throws {
        let entry = try #require(WegaPalette.foregroundRoles.first { $0.name == name }?.value)
        let badgeOpacity = 0.12

        let lightBadge = entry.light.wcag.blended(over: Self.lightBackground, opacity: badgeOpacity)
        let darkBadge = entry.dark.wcag.blended(over: Self.darkBackground, opacity: badgeOpacity)

        #expect(entry.light.wcag.contrast(against: lightBadge) >= Self.normalMinimum)
        #expect(entry.dark.wcag.contrast(against: darkBadge) >= Self.normalMinimum)
    }

    /// The fill role answers to a different pair of constraints: a filled control has to be
    /// distinguishable from the window (3:1, WCAG's non-text bar), and the ink label on it
    /// has to be readable (4.5:1).
    @Test("The honey fill stays distinguishable while its ink label stays readable")
    func fillRoleKeepsBothSidesLegible() {
        let nonTextMinimum = 3.0
        let fills = [
            (WegaPalette.honeyFill.light.wcag, Self.lightBackground),
            (WegaPalette.honeyFill.dark.wcag, Self.darkBackground),
            (WegaPalette.honeyFill.lightIncreasedContrast.wcag, Self.lightBackground),
            (WegaPalette.honeyFill.darkIncreasedContrast.wcag, Self.darkBackground),
        ]

        for (fill, background) in fills {
            #expect(fill.contrast(against: background) >= nonTextMinimum)
            #expect(WegaPalette.ink.wcag.contrast(against: fill) >= Self.normalMinimum)
        }
    }

    /// A single fixed value would have been silently correct in one appearance and wrong in
    /// the other, which is the bug this card is about.
    @Test("Light and dark are genuinely different values")
    func lightAndDarkAreNotTheSameColour() {
        for (name, entry) in WegaPalette.foregroundRoles {
            #expect(entry.light != entry.dark, "\(name) has the same value in both appearances")
        }
    }

    /// The palette is data; the `Color` constants are what the views use. This is the wire
    /// between them: resolving `Color.wegaHoney` in each appearance must hand back exactly
    /// the components declared for it.
    /// Both axes, all four corners — the selection itself, without AppKit in the way.
    @Test("Every appearance and contrast combination picks its own variant")
    func bothAxesSelectIndependently() {
        let honey = WegaPalette.honey

        #expect(honey.components(isDark: false, increasedContrast: false) == honey.light)
        #expect(honey.components(isDark: true, increasedContrast: false) == honey.dark)
        #expect(
            honey.components(isDark: false, increasedContrast: true) == honey.lightIncreasedContrast
        )
        #expect(
            honey.components(isDark: true, increasedContrast: true) == honey.darkIncreasedContrast
        )
    }

    /// The palette is data; the `Color` constants are what the views use. This is the wire
    /// between them — resolved through a real `NSAppearance`, which is the axis AppKit
    /// reports (it normalizes the high-contrast appearance names back to `.aqua`/`.darkAqua`,
    /// so that half is covered by the test above instead).
    @Test("The Color constants resolve to the declared components per appearance")
    func colorConstantsResolveThroughTheAppearance() throws {
        // Whichever way this machine has "Increase contrast" set, both branches are declared
        // above — so the expectation follows the setting instead of assuming it is off.
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let cases: [(NSAppearance.Name, WegaAdaptiveColor.Components)] = [
            (.aqua, WegaPalette.honey.components(isDark: false, increasedContrast: increased)),
            (.darkAqua, WegaPalette.honey.components(isDark: true, increasedContrast: increased)),
        ]

        for (name, expected) in cases {
            let appearance = try #require(NSAppearance(named: name))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(Color.wegaHoney).usingColorSpace(.sRGB)
            }
            let actual = try #require(resolved)

            #expect(abs(actual.redComponent - expected.red) < 0.005)
            #expect(abs(actual.greenComponent - expected.green) < 0.005)
            #expect(abs(actual.blueComponent - expected.blue) < 0.005)
        }
    }
}

// MARK: - Reduce Motion

@Suite("UX-03 — reduce motion")
struct ContinuousMotionTests {
    @Test("A forever-repeating animation becomes no animation at all")
    func foreverBecomesNothingUnderReduceMotion() {
        #expect(
            ContinuousMotion.forever(.linear(duration: 2), autoreverses: false, reduceMotion: true)
                == nil
        )
        #expect(
            ContinuousMotion.forever(.linear(duration: 2), autoreverses: false, reduceMotion: false)
                == .linear(duration: 2).repeatForever(autoreverses: false)
        )
        #expect(
            ContinuousMotion.forever(
                .easeInOut(duration: 0.65),
                autoreverses: true,
                reduceMotion: false
            ) == .easeInOut(duration: 0.65).repeatForever(autoreverses: true)
        )
    }

    @Test("Perpetual idle loops do not start under reduce motion")
    func idleLoopsStopUnderReduceMotion() {
        #expect(ContinuousMotion.loopsIdleAnimations(reduceMotion: false))
        #expect(!ContinuousMotion.loopsIdleAnimations(reduceMotion: true))
    }

    /// Every endless animation has to go through the policy above. A raw `repeatForever` in
    /// a view is exactly the bug the card describes — it cannot see the setting.
    @Test("No view builds a repeatForever animation of its own")
    func repeatForeverOnlyExistsInsideThePolicy() throws {
        var offenders: [String] = []
        for file in try UX03Sources.appViewFiles() where file.lastPathComponent != "AccessibilitySupport.swift" {
            let lines = try UX03Sources.lines(of: file)
            for (index, line) in lines.enumerated()
            where line.contains(".repeatForever(") && !UX03Sources.isComment(line) {
                offenders.append("\(file.lastPathComponent):\(index + 1)")
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A repeatForever outside ContinuousMotion cannot answer "Ogranicz ruch": \
            \(offenders.joined(separator: ", "))
            """
        )
    }

    /// The views that run an endless loop read the setting from the environment — which is
    /// also how they notice it being switched on while the loop is already running.
    @Test(
        "Every view with a perpetual animation observes the setting",
        arguments: [
            "WegaViews.swift",
            "PlayfulWega.swift",
            "UpdateViewSupport.swift",
            "SniffingScene.swift",
            "SidebarList.swift",
            "BinaryStream.swift",
        ]
    )
    func animatedViewsObserveReduceMotion(fileName: String) throws {
        let source = try UX03Sources.text(ofFileNamed: fileName)
        #expect(source.contains("@Environment(\\.accessibilityReduceMotion)"))
    }
}

// MARK: - Settings window

@Suite("UX-03 — elastic Settings window")
struct SettingsWindowElasticityTests {
    @Test("The Settings content proposes a size instead of dictating one")
    func settingsContentCanGrow() throws {
        let settings = try UX03Sources.text(ofFileNamed: "SettingsView.swift")

        #expect(!settings.contains(".frame(width: 640, height: 600)"))
        #expect(settings.contains("minWidth: WegaLayout.settingsMinWidth"))
        #expect(settings.contains("idealWidth: WegaLayout.settingsIdealWidth"))
        #expect(settings.contains("maxWidth: .infinity"))
        #expect(settings.contains("maxHeight: .infinity"))

        let app = try UX03Sources.text(ofFileNamed: "MacUpdaterApp.swift")
        #expect(app.contains(".windowResizability(.contentSize)"))
    }

    @Test("The window still opens at the size it always did, and can shrink below it")
    func settingsMetricsBracketTheOldFixedSize() {
        #expect(WegaLayout.settingsIdealWidth == 640)
        #expect(WegaLayout.settingsIdealHeight == 600)
        #expect(WegaLayout.settingsMinWidth < WegaLayout.settingsIdealWidth)
        #expect(WegaLayout.settingsMinHeight < WegaLayout.settingsIdealHeight)
    }
}

/// UX-03 — the letter tile shown when an app has no icon of its own.
///
/// The palette guard grades the semantic roles; this one was outside it, because the tile
/// builds its fill from a hash of the app's name rather than from the palette. Measured, it
/// sat at **3.00:1** — below even the 3:1 that large text is allowed, and the glyph is only
/// large text on the biggest of the three tiles (`size * 0.46` bold: 18.4pt at 40, 14.7pt at
/// 32, 12.9pt at the default 28). The smallest needed 4.5:1 and none of them reached it.
@Suite("UX-03 — the letter tile is readable at every size")
@MainActor
struct PackageLetterIconContrastTests {

    /// Red before the fix: `brightness: 0.65` gave 3.00:1 on the worst of the four hues.
    @Test func everyTileHueClearsTheStrictTextThreshold() throws {
        for hue in PackageLetterIcon.tileHues {
            let background = try tile(hue: hue)
            let letter = WCAGColor(red: 1, green: 1, blue: 1)
                .blended(over: background, opacity: PackageLetterIcon.letterOpacity)

            let ratio = letter.contrast(against: background)
            #expect(ratio >= 4.5,
                    """
                    UX-03: hue \(hue) gives \(String(format: "%.2f", ratio)):1. The default tile \
                    renders the glyph below the large-text size, so the strict 4.5:1 applies — \
                    grading it as a graphic would make readability depend on which tile you land on.
                    """)
        }
    }

    /// The fill is what carries the ratio, so it is the thing a future edit is most likely to
    /// brighten back. Named here so that edit has to pass through this test.
    @Test func theTileFillStaysAsDarkAsTheThresholdNeeds() {
        #expect(PackageLetterIcon.tileBrightness <= 0.5,
                "UX-03: above this the worst hue drops under 4.5:1 — see the measurement above")
    }

    private func tile(hue: Double, file: StaticString = #filePath) throws -> WCAGColor {
        let colour = try #require(
            NSColor(
                hue: hue,
                saturation: PackageLetterIcon.tileSaturation,
                brightness: PackageLetterIcon.tileBrightness,
                alpha: 1
            ).usingColorSpace(.sRGB)
        )
        return WCAGColor(red: colour.redComponent, green: colour.greenComponent, blue: colour.blueComponent)
    }
}

// MARK: - Helpers

/// Source-inspection helpers. A package test target cannot drive the real window, but it can
/// read the code that builds it — the same technique QA-02's accessibility tests use.
enum UX03Sources {
    /// Where the app's own views live. Kept for `text(ofFileNamed:)`, which addresses files by
    /// name; the guards themselves scan `sourcesRoot`.
    static var appViewDirectory: URL {
        packageRoot.appendingPathComponent("Sources/MacUpdater")
    }

    /// Every module, not just the one that happens to hold the views today.
    ///
    /// The scan used to be a non-recursive `contentsOfDirectory` on `Sources/MacUpdater`, so a
    /// new subdirectory under it — or a second target that imports SwiftUI — was invisible to
    /// the typography guard. Nothing escaped in practice, because nothing outside that one flat
    /// directory imports SwiftUI; the point is that nothing *would have been reported* if it
    /// did, and a guard whose blind spot grows with the codebase stops being one.
    static var sourcesRoot: URL {
        packageRoot.appendingPathComponent("Sources")
    }

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every Swift file under `Sources/` that actually builds a view. Filtering on the import
    /// rather than on a directory is what makes the rule follow the code: a file gains SwiftUI
    /// and gains the guard in the same edit.
    static func appViewFiles() throws -> [URL] {
        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("import SwiftUI") else { continue }
            files.append(url)
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func text(ofFileNamed name: String) throws -> String {
        try String(contentsOf: appViewDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    static func lines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
    }

    /// Prose about the rule is not a call site: `WegaTheme` documents both the alias it
    /// replaced and the marker that exempts a drawing.
    static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }
}

/// WCAG 2.1 arithmetic on an sRGB triple. Kept in the test rather than in the palette: the
/// app never needs to grade its own colours at runtime, only to be graded here.
struct WCAGColor {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ components: WegaAdaptiveColor.Components) {
        self.init(red: components.red, green: components.green, blue: components.blue)
    }

    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.1 contrast ratio, 1…21.
    func contrast(against other: WCAGColor) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour laid over `background` at `opacity` — how a badge's tinted fill is made.
    func blended(over background: WCAGColor, opacity: Double) -> WCAGColor {
        WCAGColor(
            red: red * opacity + background.red * (1 - opacity),
            green: green * opacity + background.green * (1 - opacity),
            blue: blue * opacity + background.blue * (1 - opacity)
        )
    }
}

extension WegaAdaptiveColor.Components {
    var wcag: WCAGColor { WCAGColor(self) }
}
