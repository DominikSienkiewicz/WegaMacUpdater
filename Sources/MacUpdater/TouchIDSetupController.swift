import Foundation
import MacUpdaterCore

/// Owns Touch ID setup state and privileged/process side effects outside SwiftUI views.
@MainActor
final class TouchIDSetupController: ObservableObject {
  enum AuthorizationOutcome: Equatable, Sendable {
    case success
    case cancelledByUser
    case permissionDenied
    case otherError(String)
  }

  enum State: Equatable {
    case idle(TouchIDSudoConfigurator.State)
    case enabling(TouchIDSudoConfigurator.State)
    case disabling(TouchIDSudoConfigurator.State)
    case permissionDenied(TouchIDSudoConfigurator.State)
    case failed(TouchIDSudoConfigurator.State, String)
  }

  /// What the card offers for turning Touch ID off, from what the app observed.
  enum DisableOffer: Equatable {
    case unknown
    case available
    case helperMissing
    case helperOutdated
    case blocked(TouchIDSudoDisableRefusal)
  }

  struct Dependencies: Sendable {
    var currentState: @Sendable () -> TouchIDSudoConfigurator.State
    var helperIsEnabled: @MainActor @Sendable () -> Bool
    var enableWithHelper: @MainActor @Sendable () async throws -> Void
    var authorizeFallback: @Sendable () async -> AuthorizationOutcome
    var openInTerminal: @Sendable (String) -> Void
    var disableWithHelper: @MainActor @Sendable () async throws -> TouchIDSudoDisableResult = { .nothingToRemove }
    var disableAvailability: @MainActor @Sendable () async -> HelperVerbAvailability = { .enabled }
    var preflight: @Sendable () -> TouchIDDisablePreflight = { .clear }

    static let live = Dependencies(
      currentState: { TouchIDSudoConfigurator.currentState() },
      helperIsEnabled: { PrivilegedHelperClient.shared.isEnabled },
      enableWithHelper: { try await PrivilegedHelperClient.shared.enableTouchIDForSudo() },
      // SEC-05: production never executes an elevated shell string. Without the
      // bounded signed helper the controller exposes the transactional Terminal flow.
      authorizeFallback: { .permissionDenied },
      openInTerminal: { command in
        let escaped =
          command
          .replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "\"", with: "\\\"")
        let script =
          "tell application \"Terminal\" to do script \"\(escaped)\"\n"
          + "tell application \"Terminal\" to activate"
        let task = Process()
        task.executableURL = SystemPaths.osascript
        task.currentDirectoryURL = ProcessRunner.childWorkingDirectory
        task.arguments = ["-e", script]
        try? task.run()
      },
      disableWithHelper: { try await PrivilegedHelperClient.shared.disableTouchIDForSudo() },
      disableAvailability: {
        await PrivilegedHelperClient.shared.availabilityAfterHandshake(for: .disableTouchIDForSudo)
      },
      preflight: { TouchIDDisablePreflight.live() }
    )
  }

  @Published private(set) var state: State
  @Published private(set) var disableOffer = DisableOffer.unknown
  private(set) var preflight = TouchIDDisablePreflight.clear

  private let dependencies: Dependencies

  init(dependencies: Dependencies = .live) {
    self.dependencies = dependencies
    state = .idle(dependencies.currentState())
    preflight = dependencies.preflight()
  }

  var touchIDState: TouchIDSudoConfigurator.State {
    switch state {
    case .idle(let value), .enabling(let value), .disabling(let value), .permissionDenied(let value): return value
    case .failed(let value, _): return value
    }
  }

  var isEnabling: Bool {
    if case .enabling = state { return true }
    return false
  }

  var isDisabling: Bool {
    if case .disabling = state { return true }
    return false
  }

  var errorMessage: String? {
    if case .failed(_, let message) = state { return message }
    return nil
  }

  var wasPermissionDenied: Bool {
    if case .permissionDenied = state { return true }
    return false
  }

  func refresh() {
    // ARCH-08a: re-checking Touch ID is the one moment the sudo/askpass wiring can
    // change mid-session, so drop the memoised brew environment. The next spawn then
    // rebuilds it and a freshly enabled Touch ID is respected immediately.
    HomebrewEnvironment.invalidateCache()
    state = .idle(dependencies.currentState())
    preflight = dependencies.preflight()
  }

  func openManualFallback() {
    dependencies.openInTerminal(TouchIDSudoConfigurator.manualEnableTerminalCommand)
  }

  func enable(onWegaState: @MainActor (WegaState) -> Void) async {
    guard !isEnabling else { return }
    state = .enabling(touchIDState)

    if dependencies.helperIsEnabled() {
      do {
        try await dependencies.enableWithHelper()
        refresh()
        onWegaState(WegaState(pose: .happy, line: tr("Touch ID podpięty pod sudo.")))
        return
      } catch {
        WegaLog.error(
          .helper,
          "Helper enableTouchIDForSudo nie powiódł się: \(error.localizedDescription)"
        )
      }
    }

    switch await dependencies.authorizeFallback() {
    case .success:
      refresh()
      onWegaState(WegaState(pose: .happy, line: tr("Touch ID podpięty pod sudo.")))
    case .cancelledByUser:
      state = .idle(touchIDState)
    case .permissionDenied:
      state = .permissionDenied(touchIDState)
      onWegaState(
        WegaState(
          pose: .alert,
          line: tr("macOS zablokował zapis — wklej komendę do Terminala.")
        ))
    case .otherError(let message):
      state = .failed(touchIDState, message)
    }
  }

  /// One bounded handshake, and only when Touch ID is on and nothing the app observed already
  /// rules the helper out, so the button appears only for a helper that will take the request.
  func refreshDisableOffer() async {
    if let refusal = preflight.refusal {
      disableOffer = .blocked(refusal)
      return
    }
    guard touchIDState == .enabled else {
      disableOffer = .unknown
      return
    }
    guard dependencies.helperIsEnabled() else {
      disableOffer = .helperMissing
      return
    }
    switch await dependencies.disableAvailability() {
    case .enabled: disableOffer = .available
    case .off: disableOffer = .helperMissing
    case .stale: disableOffer = .helperOutdated
    }
  }

  func disable(onWegaState: @MainActor (WegaState) -> Void) async {
    guard !isEnabling, !isDisabling else { return }
    guard dependencies.helperIsEnabled() else {
      state = .idle(touchIDState)
      disableOffer = .helperMissing
      return
    }
    state = .disabling(touchIDState)
    if disableOffer == .unknown { await refreshDisableOffer() }
    guard disableOffer == .available else {
      state = .idle(touchIDState)
      if disableOffer == .helperOutdated { onWegaState(Self.outdatedHelperState) }
      return
    }

    do {
      let result = try await dependencies.disableWithHelper()
      let observed = preflight
      refresh()
      let stillEnabled = touchIDState == .enabled
      var line = TouchIDDisableCopy.line(for: result, stillEnabled: stillEnabled, fallbackPath: observed.fallbackPath)
      if case .removed = result, !stillEnabled, let path = observed.unsafeLocalDirectory {
        line += " " + TouchIDDisableCopy.localDirectoryWarning(path: path)
      }
      if case .rollbackFailed = result { state = .failed(touchIDState, line) }
      onWegaState(WegaState(pose: .idle, line: line))
    } catch {
      WegaLog.error(.helper, "Helper disableTouchIDForSudo nie powiódł się: \(error.localizedDescription)")
      refresh()
      if case .versionMismatch = error as? PrivilegedHelperClient.HelperError {
        disableOffer = .helperOutdated
        onWegaState(Self.outdatedHelperState)
      } else {
        onWegaState(WegaState(pose: .idle, line: TouchIDDisableCopy.afterHelperError(stillEnabled: touchIDState == .enabled)))
      }
    }
  }

  private static var outdatedHelperState: WegaState {
    WegaState(pose: .idle, line: TouchIDDisableCopy.outdatedHelper)
  }
}
