import SwiftUI
import MacUpdaterCore

/// The inspector's "Zaufanie" (Trust) panel — the FINAL inspector increment (**I-4**). For the
/// selected update it computes the signing verdict (Team ID / publisher-change audit, code
/// signature via Gatekeeper, cask checksum) OFF the main thread and renders it.
///
/// Honesty constraint (security surface): a signal is shown ONLY when it was actually measured.
/// `path == nil` (an `OutdatedItem` — batch formula/cask/MAS/npm has no app bundle) always yields
/// `.unavailable` — never a fabricated verdict. Inspecting is read-only: it calls
/// `TeamIDLedger.classify` / `classifyCask` + `TeamIDLedger.shared.teamID(forBundleID:)`, never
/// `record(...)`, so looking at an update can never poison the ledger's baseline.
///
/// Cask keying (**I-4**): the batch-cask watchdog records publisher history under the
/// `"cask:<token>"` namespace, while a migrated app is keyed under its real bundle id. For a
/// `.cask(token)` source the probe reconciles BOTH on read (`classifyCaskOrNil`) so a cask whose
/// publisher the watchdog has been tracking correlates as `.unchanged`/`.changed` instead of
/// falsely reading `.firstSeen` — and withholds the rows entirely when neither the signature nor
/// any history is known, rather than showing a hollow placeholder.
///
/// Concurrency constraint: the probe shells out to `spctl` and reads the bundle from disk — both
/// blocking. It runs inside `Task.detached`, driven by `.task(id: probeKey)` so SwiftUI cancels and
/// restarts it when the selection changes; a cancelled probe never assigns `@State` (guarded by
/// `Task.isCancelled` after the await), so a slow probe for app A can never overwrite the panel
/// after the user has selected app B.
struct TrustPanel: View {
    let path: URL?
    /// The cask's checksum signal (UX-05). `unknown` — a cask whose download info has not been
    /// fetched yet, e.g. right after a relaunch — renders as "nieznane", never as a warning, so
    /// missing data is not mistaken for a negative verdict.
    let caskChecksum: CaskChecksumSignal
    /// The plain cask token when the inspected item's source is `.cask(token)` — lets the probe
    /// reconcile the watchdog's `"cask:<token>"` publisher history with the real bundle id (I-4).
    let caskToken: String?
    let probeKey: String

    @State private var state: TrustProbeState = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(tr("Zaufanie"))
            switch state {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(tr("Weryfikowanie…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            case .loaded(let result):
                loadedContent(result)
            }
        }
        .task(id: probeKey) {
            state = .loading
            let result = await Self.probe(path: path, caskChecksum: caskChecksum, caskToken: caskToken)
            if !Task.isCancelled {
                state = .loaded(result)
            }
        }
    }

    // MARK: Probe (no main-thread I/O)

    static func probe(path: URL?, caskChecksum: CaskChecksumSignal, caskToken: String?) async -> TrustProbeResult {
        guard let path else {
            return TrustProbeResult(
                verdict: trustLevel(audit: nil, signatureValid: nil, caskChecksumPresent: caskChecksum.checksumPresence),
                teamID: nil, audit: nil, signatureValid: nil, checksum: caskChecksum)
        }
        return await Task.detached(priority: .userInitiated) {
            let fresh = CodeSignatureVerifier.teamID(ofAppAt: path)
            let bundleID = Bundle(url: path)?.bundleIdentifier
            let audit: TeamIDAudit?
            if let caskToken {
                // A cask's publisher may be tracked under its real bundle id (a migration keys it
                // there) OR the watchdog's "cask:<token>" namespace — reconcile both on read, and
                // withhold the rows entirely when neither the signature nor any history is known.
                let byBundle = bundleID.flatMap { TeamIDLedger.shared.teamID(forBundleID: $0) }
                let byCask = TeamIDLedger.shared.teamID(forBundleID: TeamIDLedger.caskKey(caskToken))
                audit = TeamIDLedger.classifyCaskOrNil(storedByBundleID: byBundle, storedByCaskKey: byCask, new: fresh)
            } else {
                audit = bundleID.map {
                    TeamIDLedger.classify(stored: TeamIDLedger.shared.teamID(forBundleID: $0), new: fresh)
                }
            }
            let sig = CodeSignatureVerifier.passesGatekeeperForExecution(at: path)
            return TrustProbeResult(
                verdict: trustLevel(audit: audit, signatureValid: sig, caskChecksumPresent: caskChecksum.checksumPresence),
                teamID: fresh, audit: audit, signatureValid: sig, checksum: caskChecksum)
        }.value
    }

    // MARK: Display

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func loadedContent(_ result: TrustProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            verdictRow(result.verdict)
            if let audit = result.audit {
                teamIDRows(teamID: result.teamID, audit: audit)
            }
            if let signatureValid = result.signatureValid {
                signalRow(
                    label: tr("Podpis"),
                    value: signatureValid ? tr("ważny") : tr("nieważny"),
                    color: signatureValid ? Color.wegaSuccess : Color.wegaDanger)
            }
            checksumRow(result.checksum)
        }
    }

    /// The checksum signal, three-state (UX-05): `unknown` (download info not fetched yet, e.g.
    /// right after a relaunch) reads as a muted "nieznane" rather than a red "brak", so missing
    /// data is never shown as a negative verdict. `notApplicable` shows no row at all.
    @ViewBuilder
    private func checksumRow(_ signal: CaskChecksumSignal) -> some View {
        switch signal {
        case .present:
            signalRow(label: tr("Suma kontrolna"), value: tr("obecna"), color: Color.wegaSuccess)
        case .absent:
            signalRow(label: tr("Suma kontrolna"), value: tr("brak"), color: Color.wegaDanger)
        case .unknown:
            signalRow(label: tr("Suma kontrolna"), value: tr("nieznane"), color: .secondary)
        case .notApplicable:
            EmptyView()
        }
    }

    @ViewBuilder
    private func verdictRow(_ verdict: TrustLevel) -> some View {
        switch verdict {
        case .ok:
            Label(tr("Zweryfikowano"), systemImage: "checkmark.seal.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.wegaSuccess)
        case .warning:
            Label(tr("Wykryto ostrzeżenie"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.wegaDanger)
        case .unavailable:
            Label(tr("Weryfikacja niedostępna"), systemImage: "questionmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func teamIDRows(teamID: String?, audit: TeamIDAudit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            signalRow(label: tr("Wydawca (Team ID)"), value: teamID ?? "—", monospaced: true)
            switch audit {
            case .changed(let old, let new):
                Text(tr("Wydawca się zmienił:") + " \(old) → \(new ?? "—")")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.wegaDanger)
            case .firstSeen:
                Text(tr("pierwsze sprawdzenie wydawcy"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            case .unchanged:
                Text(tr("wydawca bez zmian"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// One label→value signal row. `color` defaults to primary for values that aren't
    /// good/bad-colored (e.g. the raw Team ID string).
    private func signalRow(label: String, value: String, color: Color = .primary, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: monospaced ? 11 : 12, design: monospaced ? .monospaced : .default))
                .foregroundStyle(color)
        }
    }
}

/// Result of one Trust probe pass — crosses the detached-task boundary, so it must be
/// `Sendable` under Swift 6 strict concurrency (all fields already are).
struct TrustProbeResult: Equatable, Sendable {
    var verdict: TrustLevel
    var teamID: String?
    var audit: TeamIDAudit?
    var signatureValid: Bool?
    var checksum: CaskChecksumSignal
}

enum TrustProbeState: Equatable {
    case loading
    case loaded(TrustProbeResult)
}
