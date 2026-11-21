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
    var enableWithHelper: @MainActor @Sendable () async throws -> TouchIDSudoEnableResult
    var authorizeFallback: @Sendable () async -> AuthorizationOutcome
    var openInTerminal: @Sendable (String) -> Void
    var disableWithHelper: @MainActor @Sendable () async throws -> TouchIDSudoDisableResult = { .nothingToRemove }
    var disableAvailability: @MainActor @Sendable () async -> HelperVerbAvailability = { .enabled }
    var preflight: @Sendable () -> TouchIDDisablePreflight = { .clear }
    /// Takes only the verb and the helper's code, so no path or byte of the file can reach the log.
    var logHelperCode: @Sendable (WegaHelperVerb, Int) -> Void = { verb, code in
      WegaLog.error(.helper, "Helper \(verb.rawValue): kod \(code)")
    }

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
  @Published private(set) var enableHelperOutdated = false
  /// −4 or −5 a helper call reported, in either direction. Root may see what the app cannot, so it
  /// is kept until a helper call succeeds, reading the file again included (RC2-7).
  @Published private(set) var helperReportedUnsafePolicy: TouchIDSudoDisableRefusal?
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

  /// The manual Terminal command runs through `sudo`, so the card offers it only after the helper
  /// could not do it, and only on proof that what `sudo` reads is safe.
  var showsEnableCommand: Bool { wasPermissionDenied && recoveryOnlyReason == nil }

  var helperObservedUnsafePolicy: Bool { helperReportedUnsafePolicy != nil }

  /// −4 or −5 that the app's own look or the helper saw.
  var unsafePolicy: TouchIDSudoDisableRefusal? { preflight.refusal ?? helperReportedUnsafePolicy }

  /// Why the card offers no `sudo` route at all, neither a Terminal command nor a helper button, only
  /// recoveryOS advice: `sudo` reads these settings before it asks for anything (RC2-6, RC2-7).
  enum RecoveryOnlyReason: Equatable {
    /// −4 or −5, as the app saw it or a helper call reported it.
    case unsafePolicy(TouchIDSudoDisableRefusal)
    /// The app saw that someone other than root can change `/etc/pam.d/sudo`.
    case unsafeSudoFile
    /// The app could not establish that the settings are root's alone; treated like −5.
    case noProofOfSafety
  }

  /// What was seen comes before what could not be established.
  var recoveryOnlyReason: RecoveryOnlyReason? {
    if let unsafePolicy { return .unsafePolicy(unsafePolicy) }
    if preflight.sudoPolicyIsUnsafe { return .unsafeSudoFile }
    return preflight.commandsAreSafe ? nil : .noProofOfSafety
  }

  var offersEnableButton: Bool { touchIDState == .available && !wasPermissionDenied && recoveryOnlyReason == nil }

  var offersDisableButton: Bool { touchIDState == .enabled && disableOffer == .available && recoveryOnlyReason == nil }

  /// Aneks E.6: without a helper that can do it, the Terminal command, but only when nothing closes
  /// the `sudo` routes, no later policy file would take over, and the app's own read of `sudo_local`
  /// plans a removal by the helper's rules. The command checks all of it again when it runs.
  var showsDisableCommand: Bool {
    guard touchIDState == .enabled, disableOffer == .helperMissing || disableOffer == .helperOutdated,
          recoveryOnlyReason == nil, preflight.fallbackPath == nil, case .remove? = preflight.removalPlan
    else { return false }
    return true
  }

  func refresh() {
    // ARCH-08a: re-checking Touch ID is the one moment the sudo/askpass wiring can
    // change mid-session, so drop the memoised brew environment. The next spawn then
    // rebuilds it and a freshly enabled Touch ID is respected immediately.
    HomebrewEnvironment.invalidateCache()
    state = .idle(dependencies.currentState())
    preflight = dependencies.preflight()
    enableHelperOutdated = false
  }

  func openManualFallback() {
    dependencies.openInTerminal(TouchIDSudoConfigurator.manualEnableTerminalCommand)
  }

  func enable(onWegaState: @MainActor (WegaState) -> Void) async {
    guard !isEnabling else { return }
    state = .enabling(touchIDState)
    enableHelperOutdated = false

    if dependencies.helperIsEnabled() {
      do {
        finishEnabling(with: try await dependencies.enableWithHelper(), onWegaState: onWegaState)
        return
      } catch {
        WegaLog.error(
          .helper,
          "Helper enableTouchIDForSudo nie powiódł się: \(error.localizedDescription)"
        )
        if case .versionMismatch = error as? PrivilegedHelperClient.HelperError {
          enableHelperOutdated = true
          state = .permissionDenied(touchIDState)
          onWegaState(WegaState(pose: .idle, line: TouchIDEnableCopy.outdatedHelper))
          return
        }
        // Z13: no answer does not mean nothing changed; the helper may have finished under its lock.
        refresh()
        if touchIDState == .enabled {
          onWegaState(Self.enabledState)
          return
        }
        state = .enabling(touchIDState)
      }
    }

    switch await dependencies.authorizeFallback() {
    case .success:
      refresh()
      onWegaState(Self.enabledState)
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

  /// RC2-2: a success only when the file read again says so. A refusal or a failed write shows its
  /// line and never falls into the Terminal command, which goes through `sudo` as well [O14].
  private func finishEnabling(with result: TouchIDSudoEnableResult, onWegaState: @MainActor (WegaState) -> Void) {
    noteHelperReply(.enableTouchIDForSudo, code: result.wireCode)
    refresh()
    let isEnabled = touchIDState == .enabled
    let line = TouchIDEnableCopy.line(for: result, isEnabled: isEnabled)
    if isEnabled, result == .enabled || result == .alreadyEnabled {
      onWegaState(WegaState(pose: .happy, line: line))
      return
    }
    if case .rollbackFailed = result { state = .failed(touchIDState, line) }
    onWegaState(WegaState(pose: .idle, line: line))
  }

  private static var enabledState: WegaState {
    WegaState(pose: .happy, line: TouchIDEnableCopy.line(for: .enabled, isEnabled: true))
  }

  /// Both directions share the codes: 0 and above is the helper's success, −4 and −5 an unsafe
  /// policy. A refusal or a failure is logged by its code alone.
  private func noteHelperReply(_ verb: WegaHelperVerb, code: Int) {
    if code >= 0 {
      helperReportedUnsafePolicy = nil
      return
    }
    dependencies.logHelperCode(verb, code)
    if let refusal = TouchIDSudoDisableRefusal(rawValue: code), refusal == .notRegularFile || refusal == .unsafeOwnership {
      helperReportedUnsafePolicy = refusal
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
      noteHelperReply(.disableTouchIDForSudo, code: result.wireCode)
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
        return
      }
      onWegaState(WegaState(pose: .idle, line: TouchIDDisableCopy.afterHelperError(stillEnabled: touchIDState == .enabled)))
    }
    await refreshDisableOffer()
  }

  private static var outdatedHelperState: WegaState {
    WegaState(pose: .idle, line: TouchIDDisableCopy.outdatedHelper)
  }
}
