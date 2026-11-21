import SwiftUI
import MacUpdaterCore

/// One cask in the plan preview (F2): download host, checksum status, rollback coverage,
/// a possible admin-password prompt, and the download size.
///
/// Every field is allowed to say "I don't know". `brew info --json` has no size, so a size
/// is a HEAD probe away and a CDN may still withhold `Content-Length`; a `pkg`/`installer`/
/// `preflight` stanza is visible but its contents are not, so the password note says *may*.
struct PlanPreviewCaskRow: View {
    let token: String
    let download: CaskDownloadInfo?
    let protection: RollbackProtection.Verdict?
    let mayNeedPassword: Bool
    let size: DownloadSizeProbeResult?

    private var host: String {
        download?.url.flatMap { URL(string: $0)?.host() } ?? tr("nieznany host")
    }

    private var sizeLabel: String {
        switch size {
        case .known(let bytes):
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        case .unknown, .failed:
            return tr("rozmiar nieznany")
        case nil:
            return "—"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(token)
                    .font(.wega(.subheadline, weight: .medium, monospaced: true))
                    .frame(width: 150, alignment: .leading)
                Text(host)
                    .font(.wega(.footnote))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if download?.hasChecksum == true {
                    Label(tr("suma zostanie sprawdzona"), systemImage: "checkmark.seal")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .help(tr("suma zostanie sprawdzona"))
                } else {
                    Label(tr("źródło nie podaje sumy do sprawdzenia"), systemImage: "exclamationmark.shield")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.wegaDanger)
                        .help(tr("źródło nie podaje sumy do sprawdzenia"))
                }
                if protection == .protected {
                    Image(systemName: "shield.lefthalf.filled").foregroundStyle(Color.wegaSuccess)
                        .help(RollbackScopePresentation.notice(for: RollbackProtection.scope(token: token))?.localizedDescription
                              ?? tr("Chronione automatycznym cofnięciem"))
                } else if protection != nil {
                    Image(systemName: "shield.slash").foregroundStyle(.tertiary)
                        .help(tr("Bez ochrony cofnięciem"))
                }
                if mayNeedPassword {
                    Image(systemName: "key").foregroundStyle(Color.wegaToffee)
                        .help(tr("Może poprosić o hasło administratora."))
                }
                Text(sizeLabel)
                    .font(.wega(.footnote, monospaced: true))
                    .foregroundStyle(.tertiary)
                    .frame(width: 96, alignment: .trailing)
            }
            .font(.wega(.subheadline))
            if protection == .protected {
                RollbackScopeNotice(scope: RollbackProtection.scope(token: token))
            }
        }
    }
}
