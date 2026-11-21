import SwiftUI
import MacUpdaterCore

/// UXP-11 — the user's ignore, pin and skip rules, one row each with "Przywróć", which removes
/// the rule and nothing else: the update comes back to the list, never into the queue. Settings
/// lists every rule; the Updates sheet only the rules that hide something the scan found.
struct PolicyRulesList: View {
    let entries: [UpdatePolicyEntry]
    let onRestore: (UpdatePolicyEntry) -> Void

    var body: some View {
        ForEach(entries) { entry in
            HStack(spacing: 10) {
                Image(systemName: Self.icon(for: entry.policy))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName).font(.wega(.body, weight: .medium))
                    Text(Self.description(of: entry.policy))
                        .font(.wega(.subheadline))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(tr("Przywróć")) { onRestore(entry) }
                    .controlSize(.small)
                    .help(tr("Usuń regułę"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            if entry.id != entries.last?.id {
                Divider().opacity(0.4).padding(.leading, 42)
            }
        }
    }

    private static func icon(for policy: UpdatePolicy) -> String {
        switch policy {
        case .ignored: return "bell.slash"
        case .pinned:  return "pin"
        case .skipped: return "forward.end"
        }
    }

    private static func description(of policy: UpdatePolicy) -> String {
        switch policy {
        case .ignored:              return tr("Ignorowane")
        case .pinned(let version):  return trf("Przypięte do %@", version)
        case .skipped(let version): return trf("Pominięta wersja %@", version)
        }
    }
}

/// UXP-11 — the rules behind "Ukryte przez Twoje reguły", opened from the Updates list.
struct PolicyRulesSheet: View {
    let entries: [UpdatePolicyEntry]
    let onRestore: (UpdatePolicyEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Ignorowane i przypięte"))
                .font(.wega(.title3, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PolicyRulesList(entries: entries, onRestore: onRestore)
                }
            }
            HStack {
                Spacer()
                Button(tr("Zamknij")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 240, idealHeight: 360)
        // After the last "Przywróć" nothing is left to show.
        .onChange(of: entries.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }
}

/// UXP-11 — the line under the list that says how many of the user's rules hide something from
/// this scan, and opens them. It shows under the empty state too, so hiding the last update
/// never leaves the list without the way back.
struct HiddenByRulesRow: View {
    let count: Int
    let onShow: () -> Void

    var body: some View {
        Button(action: onShow) {
            HStack(spacing: 6) {
                Label(trf("Ukryte przez Twoje reguły: %@ · Pokaż", "\(count)"), systemImage: "eye.slash")
                Image(systemName: "chevron.right")
                    .font(.wega(.caption, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.wega(.subheadline))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// UXP-11 — "Nie aktualizuj" or a skip just hid a row; "Cofnij" takes the change back. The
/// toast closes itself after `lifetime`, counted on the callout it draws, so the countdown
/// never hangs on a container that may be empty. While VoiceOver runs it waits for the user
/// instead (WCAG 2.2.1): the store has announced it, and a timeout would take "Cofnij" away
/// before it can be reached.
struct RuleUndoToast: View {
    static let lifetime: Duration = .seconds(8)

    let notice: RuleUndoNotice
    let onUndo: () -> Void
    let onClose: () -> Void
    /// The wait before the toast closes itself; tests pass one that returns at once.
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverRunning

    var body: some View {
        WegaCallout(.info, title: notice.message, onClose: onClose) {
            Button(tr("Cofnij"), action: onUndo)
        }
        .task(id: Countdown(notice: notice.id, voiceOverRunning: voiceOverRunning)) {
            await Self.countDown(Self.lifetime, voiceOverRunning: voiceOverRunning, sleep: sleep, then: onClose)
        }
    }

    /// What restarts the countdown: a new toast, or VoiceOver starting or stopping.
    private struct Countdown: Equatable {
        let notice: RuleUndoNotice.ID
        let voiceOverRunning: Bool
    }

    /// Waits out `lifetime`, then closes; with VoiceOver running it never starts. A countdown
    /// cancelled first — the toast was closed, or replaced by the next change's — closes nothing.
    static func countDown(
        _ lifetime: Duration,
        voiceOverRunning: Bool,
        sleep: (Duration) async throws -> Void,
        then expire: () -> Void
    ) async {
        guard !voiceOverRunning else { return }
        do { try await sleep(lifetime) } catch { return }
        guard !Task.isCancelled else { return }
        expire()
    }
}
