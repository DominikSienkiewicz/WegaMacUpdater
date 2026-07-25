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
    case permissionDenied(TouchIDSudoConfigurator.State)
    case failed(TouchIDSudoConfigurator.State, String)
  }

  struct Dependencies: Sendable {
    var currentState: @Sendable () -> TouchIDSudoConfigurator.State
    var helperIsEnabled: @MainActor @Sendable () -> Bool
    var enableWithHelper: @MainActor @Sendable () async throws -> Void
    var authorizeFallback: @Sendable () async -> AuthorizationOutcome
    var openInTerminal: @Sendable (String) -> Void

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
        task.arguments = ["-e", script]
        try? task.run()
      }
    )
  }

  @Published private(set) var state: State

  private let dependencies: Dependencies

  init(dependencies: Dependencies = .live) {
    self.dependencies = dependencies
    state = .idle(dependencies.currentState())
  }

  var touchIDState: TouchIDSudoConfigurator.State {
    switch state {
    case .idle(let value), .enabling(let value), .permissionDenied(let value): return value
    case .failed(let value, _): return value
    }
  }

  var isEnabling: Bool {
    if case .enabling = state { return true }
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
    state = .idle(dependencies.currentState())
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

}
