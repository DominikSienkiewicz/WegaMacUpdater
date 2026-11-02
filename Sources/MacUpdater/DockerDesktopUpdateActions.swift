import AppKit
import SwiftUI
import MacUpdaterCore

struct DockerDesktopUpdateActions: View {
    let item: ManualOutdatedApp
    let busyToken: String?
    let onInstall: (String) -> Void

    @EnvironmentObject private var scan: ScanStore
    @State private var confirmHomebrew = false

    private var homebrewToken: String? {
        DockerDesktopUpdatePolicy.homebrewToken(for: item)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                scan.vendorOpened(item, succeeded: item.path.isFileURL && NSWorkspace.shared.open(item.path))
            } label: {
                Label(tr("Otwórz Docker Desktop"), systemImage: "arrow.up.forward.app")
            }
            .controlSize(.small)
            Text(tr("W menu Docker wybierz Check for updates. Otwarcie aplikacji nie potwierdza aktualizacji."))
                .font(.wega(.footnote))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320, alignment: .trailing)
            if let token = homebrewToken {
                Button {
                    confirmHomebrew = true
                } label: {
                    if busyToken == token {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(tr("Użyj Homebrew…"))
                    }
                }
                .controlSize(.small)
                .disabled(busyToken != nil)
                .confirmationDialog(tr("Zaktualizować Docker Desktop przez Homebrew?"),
                                    isPresented: $confirmHomebrew, titleVisibility: .visible) {
                    Button(tr("Aktualizuj przez Homebrew")) { onInstall(token) }
                    Button(tr("Anuluj"), role: .cancel) {}
                } message: {
                    Text(tr("Homebrew zastąpi aplikację dopiero po potwierdzonym zatrzymaniu Docker Desktop. Cofnięcie obejmuje tylko aplikację, bez danych Dockera. Reset fabryczny nie jest częścią naprawy."))
                }
            }
        }
    }
}

struct UnresolvedDockerUpdateRow: View {
    let item: OutdatedItem
    let onInspect: () -> Void

    var body: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 8) {
                WegaCardHeader(icon: "shippingbox", title: "Docker Desktop", count: 1, note: item.name)
                VersionArrow(from: item.from ?? "—", to: item.to ?? "—")
                Text(tr("Wykryto aktualizację Docker Desktop, ale ścieżka aplikacji jest nieznana. Otwórz Docker Desktop samodzielnie lub ponów skanowanie."))
                    .font(.wega(.subheadline))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("Pokaż szczegóły"), action: onInspect).controlSize(.small)
            }
            .padding(12)
        }
    }
}
