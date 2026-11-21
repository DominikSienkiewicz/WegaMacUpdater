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
        #expect(view.contains("CaskDisplayName.labels(for: casks.map { ($0.name, scan.caskIconPaths[$0.name]) })"))
        #expect(!view.contains("private struct PlanPreviewCaskRow"))
        #expect(try source("Sources/MacUpdater/PlanPreviewCaskRow.swift").contains("Text(token)"))
        #expect(try source("Sources/MacUpdater/InspectorPane.swift").contains("CaskDisplayName.name(token: item.name, appPath: iconPath)"))
        #expect(try source("Sources/MacUpdater/UpdateViewSupport.swift").contains("CaskDisplayName.name(token: item.token, appPath: URL(fileURLWithPath: item.appPath))"))
        #expect(try source("Sources/MacUpdater/RollbackView.swift").contains("CaskDisplayName.name(token: $0.token, appPath: URL(fileURLWithPath: $0.appPath))"))
    }

    @Test func theTokenLineIsNeverCutAtTheNarrowestDetailWidth() {
        let captionLine = NSLayoutManager().defaultLineHeight(for: NSFont.preferredFont(forTextStyle: .caption1))
        for language in [AppLanguage.pl, AppLanguage.en] {
            withLanguage(language) {
                let name = "Visual Studio Code"
                let token = "visual-studio-code-insiders-extended-edition-with-a-very-long-token-name"
                let without = rowHeight(name: name, token: nil, source: nil)
                let short = rowHeight(name: name, token: "vscode", source: nil)
                let with = rowHeight(name: name, token: token, source: nil)
                #expect(short >= without + captionLine,
                        "\(language): the token line adds at least one caption line (\(short) vs \(without))")
                #expect(with >= short + captionLine,
                        "\(language): a long token wraps instead of being cut (\(with) vs \(short))")
            }
        }
    }

    @Test func undoNamesTheTokenOnlyWhenItDiffersFromTheAppName() {
        func height(appPath: String) -> CGFloat {
            let update = UndoableUpdate(operationID: UUID(), token: "slack", appPath: appPath,
                                        restoredVersion: "1", updatedAt: Date(), expiresAt: Date().addingTimeInterval(60))
            let section = UndoUpdateSection(items: [update], busyToken: nil, onUndo: { _ in }).frame(width: 520)
            return NSHostingView(rootView: section).fittingSize.height
        }
        #expect(height(appPath: "/Applications/Slack Beta.app") > height(appPath: "/Applications/slack.app"))
    }

    @Test func twoCasksWithOneAppNameAreToldApartByToken() {
        let beta = URL(fileURLWithPath: "/Applications/Firefox.app")
        let labels = CaskDisplayName.labels(for: [("firefox", beta), ("firefox@beta", beta), ("slack", nil)])
        #expect(labels == ["Firefox (firefox)", "Firefox (firefox@beta)", "slack"])
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
