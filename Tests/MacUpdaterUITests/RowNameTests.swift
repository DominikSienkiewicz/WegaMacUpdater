import AppKit
import Foundation
import SwiftUI
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

@Suite("Row names") @MainActor
struct RowNameTests {
    @Test func casksShowTheAppAndKeepTheTokenUnderIt() throws {
        let support = try source("Sources/MacUpdater/UpdateViewSupport.swift")
        let section = try #require(support.range(of: "struct UpdateSection: View")).upperBound
        let body = support[section...].prefix(4000)
        #expect(body.contains("CaskDisplayName.name(token: item.name, appPath: iconPaths[item.name])"))
        #expect(body.contains("token:          item.kind == .cask ? item.name : nil"))
        let shared = try source("Sources/MacUpdater/SharedViews.swift")
        let row = try #require(shared.range(of: "private var identity: some View")).upperBound
        #expect(shared[row...].prefix(700).contains("\"\\(token) · \\($0)\""))
    }

    @Test func theDialogTheInspectorAndUndoSpeakNamesButThePlanKeepsTokens() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        #expect(view.contains("CaskDisplayName.name(token: item.name, appPath: scan.caskIconPaths[item.name])"))
        #expect(!view.contains("private struct PlanPreviewCaskRow"))
        #expect(try source("Sources/MacUpdater/PlanPreviewCaskRow.swift").contains("Text(token)"))
        #expect(try source("Sources/MacUpdater/InspectorPane.swift").contains("CaskDisplayName.name(token: item.name, appPath: iconPath)"))
        #expect(try source("Sources/MacUpdater/UpdateViewSupport.swift").contains("CaskDisplayName.name(token: item.token, appPath: URL(fileURLWithPath: item.appPath))"))
        #expect(try source("Sources/MacUpdater/RollbackView.swift").contains("CaskDisplayName.name(token: $0.token, appPath: URL(fileURLWithPath: $0.appPath))"))
    }

    @Test func theNameAndTokenRowKeepsItsTokenLineAtTheNarrowestDetailWidth() {
        for language in [AppLanguage.pl, AppLanguage.en] {
            withLanguage(language) {
                let name = "Visual Studio Code Insiders Edition Extended"
                let token = "visual-studio-code-insiders-extended"
                let oneLine = rowHeight(name: name, token: nil, source: "Homebrew")
                let withToken = rowHeight(name: name, token: token, source: "Homebrew")
                let tokenOnly = rowHeight(name: name, token: token, source: nil)
                #expect(withToken >= oneLine, "\(language): token + source is at least the source-only row")
                #expect(withToken <= oneLine + 20, "\(language): token + source adds at most one wrapped line, got \(withToken) vs \(oneLine)")
                #expect(tokenOnly > 0)
            }
        }
    }

    private func rowHeight(name: String, token: String?, source: String?) -> CGFloat {
        let row = PackageRow(name: name, token: token, currentVersion: "1.0.0", latestVersion: "2.0.0",
                             isSelected: false, source: source, onToggle: {})
            .frame(width: 420)
        return NSHostingView(rootView: row).fittingSize.height
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
