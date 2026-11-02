import AppKit
import SwiftUI
import MacUpdaterCore

struct ServiceVendorUpdateControls: View {
    let profile: ServiceVendorUpdateProfile
    let appURL: URL?
    var onOpen: ((Bool) -> Void)?
    @State private var openingFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr(profile.instructions))
                .font(.wega(.footnote))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let appURL, appURL.isFileURL {
                    Button {
                        let opened = NSWorkspace.shared.open(appURL)
                        openingFailed = !opened
                        onOpen?(opened)
                    } label: {
                        Label(tr("Otwórz aplikację"), systemImage: "arrow.up.forward.app")
                    }
                    .controlSize(.small)
                }
                if let url = profile.supportURL {
                    Link(tr("Instrukcje producenta"), destination: url)
                }
            }
            if openingFailed {
                Text(tr("Nie udało się otworzyć aplikacji lub strony producenta."))
                    .font(.caption).foregroundStyle(Color.wegaHoney)
            }
            Text(tr("Otwarcie aplikacji nie potwierdza aktualizacji. Aktualność produktu pozostaje niepotwierdzona bez porównania wersji."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct UnresolvedServiceUpdateRow: View {
    let item: OutdatedItem
    let onInspect: () -> Void

    var body: some View {
        if let profile = ServiceVendorUpdateProfile.profile(caskToken: item.name) {
            WegaCard {
                VStack(alignment: .leading, spacing: 8) {
                    WegaCardHeader(icon: "gearshape.2", title: profile.name, count: 1, note: "Homebrew")
                    VersionArrow(from: item.from ?? "—", to: item.to ?? "—")
                    Text(tr("Homebrew zgłasza aktualizację, ale nie potwierdzono ścieżki tej aplikacji. Otwórz ją samodzielnie lub ponów skanowanie."))
                        .font(.wega(.subheadline)).foregroundStyle(.secondary)
                    ServiceVendorUpdateControls(profile: profile, appURL: nil)
                    Button(tr("Pokaż szczegóły"), action: onInspect).controlSize(.small)
                }
                .padding(12)
            }
        }
    }
}
