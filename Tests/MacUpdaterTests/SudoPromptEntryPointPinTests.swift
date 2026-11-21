import Foundation
import Testing

/// Owner decision 2026-11-21: every route on which Wega could ask for the administrator password
/// consults `SudoPasswordPromptGate` before it asks. A new file that names an askpass, passes `-A`
/// or runs `/usr/bin/sudo` must be added here with the gate it consults.
@Suite("Sudo prompt entry points consult the gate")
struct SudoPromptEntryPointPinTests {
    /// What makes a file a route to a password prompt, in code rather than comments.
    private static let markers = ["SUDO_ASKPASS", "\"-A\"", "askpassExecutable", "NSSecureTextField",
                                  "SystemPaths.sudo", "/usr/bin/sudo", "\"sudo\""]

    /// Every file with a marker, and why it is not a route of its own.
    private static let notRoutes: [String: String] = [
        "Sources/MacUpdaterCore/AuthorizationComponents.swift": "resolves and verifies the askpass; the sanitiser's allowlist",
        "Sources/WegaHelperKit/SystemPaths.swift": "defines the path",
        "Sources/WegaHelperKit/TouchIDSudoConfigurator.swift": "the Terminal commands, shown only while recoveryOnlyReason is nil",
        "Sources/MacUpdaterCore/AskpassHelper.swift": "the legacy script writer, unused by the app",
        "Sources/MacUpdaterCore/SudoShim.swift": "the legacy script writer, unused by the app",
    ]

    /// Every route, and the code that shows it asks the gate.
    private static let routes: [String: [String]] = [
        "Sources/MacUpdaterCore/HomebrewEnvironment.swift": [
            "return passwordPromptsAllowed ? resolved : withoutPasswordPrompts(resolved)",
            "return SudoPasswordPromptGate.shared.allowsPasswordPrompts",
            "if promptsAllowed, let components = try? AuthorizationComponentResolver().resolveAndVerify() {",
            "[promptsAllowed ? \"-A\" : \"-n\"] + arguments",
        ],
        "Sources/MacUpdaterCore/MasService.swift": [
            "passwordPromptsAllowed: @escaping @Sendable () -> Bool = { SudoPasswordPromptGate.shared.check() == nil }",
            "guard !holdingPasswordPrompts, passwordPromptsAllowed() else {\n            throw MasServiceError.passwordPromptHeld(arguments: arguments)\n        }\n        try await prewarmSudoTimestamp()",
        ],
        "Sources/WegaSudoShim/main.swift": [
            "let promptsAllowed = SudoPasswordPromptGate.liveReason() == nil",
            "forwarding: Array(CommandLine.arguments.dropFirst()), promptsAllowed: promptsAllowed",
            "overrides: HomebrewEnvironment.trustedSudoShimOverrides(promptsAllowed: promptsAllowed)",
        ],
        "Sources/WegaAskpass/main.swift": [
            "if SudoPasswordPromptGate.liveReason() != nil {",
        ],
    ]

    @Test func everyFileThatCouldAskIsARouteThatConsultsTheGateOrIsNoRoute() throws {
        for (path, text) in try swiftSources(under: "Sources") {
            let code = code(text)
            guard Self.markers.contains(where: { code.contains($0) }), Self.notRoutes[path] == nil else { continue }
            let required = try #require(Self.routes[path], "\(path) can reach a password prompt: consult SudoPasswordPromptGate and list it here")
            for line in required {
                #expect(code.contains(line), "\(path) must keep, outside a comment: \(line)")
            }
        }
        for path in Self.routes.keys {
            #expect(FileManager.default.fileExists(atPath: packageRoot().appendingPathComponent(path).path), "\(path)")
        }
    }

    @Test func theAskpassAsksTheGateBeforeAnyPasswordFieldExists() throws {
        let askpass = try source("Sources/WegaAskpass/main.swift")
        let gate = try #require(askpass.range(of: "SudoPasswordPromptGate.liveReason()"))
        let field = try #require(askpass.range(of: "NSSecureTextField("))
        let exit = try #require(askpass.range(of: "exit(EXIT_FAILURE)"))
        #expect(gate.lowerBound < exit.lowerBound && exit.lowerBound < field.lowerBound)
        #expect(try source("Package.swift").contains("name: \"WegaAskpass\",\n            dependencies: [\"MacUpdaterCore\"],"))
    }

    @Test func theLegacyScriptWritersStayUnused() throws {
        for (path, text) in try swiftSources(under: "Sources")
        where path != "Sources/MacUpdaterCore/AskpassHelper.swift" && path != "Sources/MacUpdaterCore/SudoShim.swift" {
            #expect(!code(text).contains("AskpassHelper."), "\(path)")
            #expect(!code(text).contains("SudoShim."), "\(path)")
        }
    }

    /// The window run: a start check, a check before each cask that may ask, and the App Store batch.
    @Test func theRunAsksTheGateAtItsStartAndBeforeEachCaskThatMayAsk() throws {
        let store = try source("Sources/MacUpdater/ScanStore.swift")
        let live = try slice(store, from: "static let live = ScanStoreDependencies(", to: "\n    )\n")
        #expect(live.contains("sudoPolicyDistrust: { SudoPasswordPromptGate.shared.check() }"))
        let updating = try source("Sources/MacUpdater/ScanStore+Updating.swift")
        #expect(updating.contains("beginPasswordHold(plannedCaskNames: plannedCaskNames, planned: plannedItems)"))
        #expect(updating.contains("passwordHold = dependencies.sudoPolicyDistrust()"))
        let lanes = try source("Sources/MacUpdater/ScanStore+UpgradeLanes.swift")
        let serial = try slice(lanes, from: "for token in lanes.serial {", to: "return inPlanOrder(results, plan: items)")
        #expect(serial.contains("upgradeCaskGated(item: item, preparation: preparation, mayAskForPassword: true)"))
        let gated = try slice(lanes, from: "private func upgradeCaskGated(", to: "return await upgradeOneCask(")
        #expect(gated.contains("if mayAskForPassword, holdsPasswordPrompt(for: item) {"))
        let hold = try slice(lanes, from: "func holdsPasswordPrompt(for item: OutdatedItem) -> Bool {", to: "return true")
        #expect(hold.contains("if passwordHold == nil { passwordHold = dependencies.sudoPolicyDistrust() }"))
        #expect(lanes.contains("if case MasServiceError.passwordPromptHeld = error {"))
        #expect(lanes.contains("model.masService.upgrade(appStoreIDs: appStoreIDs, holdingPasswordPrompts: passwordHold != nil)"))
        // Review 1: held casks take no part in the preparation, and stay held on the board.
        #expect(updating.contains("prepareForegroundCasks(runnableCaskNames, targetKeys: targetKeys.subtracting(heldForPasswordKeys))"))
        #expect(store.contains("board.rows[item.key] != nil && board.rows[item.key] != .heldForPassword"))
    }

    /// Review 3 and 4: the banner's button is the card, and the warning above the list names what
    /// the run holds.
    @Test func theBannerAndTheWarningPointAtTheCard() throws {
        let views = try source("Sources/MacUpdater/SharedViews.swift")
        #expect(views.contains("case .openTouchIDCard: return tr(\"Otwórz kartę Touch ID\")"))
        #expect(try source("Sources/MacUpdater/ScanBannerHost.swift").contains("case .openSettings, .openTouchIDCard:"))
        #expect(try source("Sources/MacUpdater/UpdateView.swift").contains("PasswordPromptNotice.heldTokens("))
        #expect(try source("Sources/MacUpdater/ScanStore+Updating.swift").contains("action: sudoAction,"))
    }

    /// The readiness card reads the gate with the probe it already runs, and its held password row
    /// opens the Touch ID card instead of offering Touch ID or the helper.
    @Test func theReadinessCardReadsTheGateAndItsHeldRowOpensTheTouchIDCard() throws {
        let card = try source("Sources/MacUpdater/ReadinessCard.swift")
        let probe = try slice(card, from: "PasswordPromptNotice.Probe(", to: "}.value")
        #expect(probe.contains("sudoDistrust: SudoPasswordPromptGate.shared.check()"))
        #expect(card.contains("sudoDistrust = probe.sudoDistrust"))
        let held = try slice(card, from: "case .passwordHeld:", to: "case .notifications:")
        #expect(held.contains("Button(tr(\"Otwórz kartę Touch ID\"), action: actions.openTouchIDCard)"))
        #expect(!held.contains("Włącz Touch ID"))
        #expect(card.contains("openTouchIDCard: { SettingsRoute.shared.open(.touchID, with: openSettings) }"))
    }

    /// The Touch ID card shares the app's gate, and its two Terminal commands, which run
    /// `/usr/bin/sudo`, follow the same reason.
    @Test func theTouchIDCardSharesTheGateAndItsCommandsFollowIt() throws {
        let controller = try source("Sources/MacUpdater/TouchIDSetupController.swift")
        let live = try slice(controller, from: "static let live = Dependencies(", to: "\n    )\n")
        #expect(live.contains("promptGate: .shared"))
        #expect(controller.contains("var showsEnableCommand: Bool { wasPermissionDenied && recoveryOnlyReason == nil }"))
        let disable = try slice(controller, from: "var showsDisableCommand: Bool {", to: "return true")
        #expect(disable.contains("recoveryOnlyReason == nil"))
        #expect(controller.contains("preflight.recoveryOnlyReason(helperReported: helperReportedUnsafePolicy)"))
    }

    // MARK: Source access

    /// The text outside `//` comments, so a comment that names a marker, or a commented-out gate,
    /// does not count. A comment is a line that starts with `//` or what follows ` //` on a line;
    /// `https://` inside a string is neither.
    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return "" }
                return line.range(of: " //").map { String(line[..<$0.lowerBound]) } ?? String(line)
            }
            .joined(separator: "\n")
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftSources(under relativePath: String) throws -> [(path: String, text: String)] {
        let root = packageRoot()
        let enumerator = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(relativePath), includingPropertiesForKeys: nil))
        return try enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map { url in
            (url.path.replacingOccurrences(of: root.path + "/", with: ""), try String(contentsOf: url, encoding: .utf8))
        }
    }

    private func slice(_ text: String, from start: String, to end: String) throws -> String {
        let lower = try #require(text.range(of: start), "\(start) must exist")
        let upper = try #require(text[lower.upperBound...].range(of: end), "\(end) must follow \(start)")
        return String(text[lower.lowerBound..<upper.upperBound])
    }
}
