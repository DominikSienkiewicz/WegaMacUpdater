import AppKit
import SwiftUI
import XCTest

@testable import WegaMacUpdater

/// The Updates band's round button and band view: fixed geometry and the structure that keeps
/// VoiceOver order and the dark palette honest.
@MainActor
final class UpdateBandViewTests: XCTestCase {

    private func fittingSize(ofButtonWith diameter: CGFloat, disabled: Bool) -> CGSize {
        let button = UpdateBandButton(
            title: "Aktualizuj", count: 3, accessibilityLabel: "x", diameter: diameter
        ) {}
        .disabled(disabled)
        return NSHostingView(rootView: button).fittingSize
    }

    func testTheButtonIsExactlyItsDiameter() {
        for diameter in [WegaLayout.bandButtonSize, WegaLayout.bandButtonCompactSize] {
            for disabled in [false, true] {
                XCTAssertEqual(
                    fittingSize(ofButtonWith: diameter, disabled: disabled),
                    CGSize(width: diameter, height: diameter),
                    "diameter \(diameter), disabled \(disabled)"
                )
            }
        }
    }

    func testTheButtonDrawsItsStateFromIsEnabled() throws {
        let text = try source("Sources/MacUpdater/UpdateBandButton.swift")
        for literal in [
            "@Environment(\\.isEnabled)", ".contentShape(Circle())",
            ".accessibilityLabel(accessibilityLabel)", "Button(action: action)",
        ] {
            XCTAssertTrue(text.contains(literal), literal)
        }
        XCTAssertFalse(text.contains(".system(size:"))
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
