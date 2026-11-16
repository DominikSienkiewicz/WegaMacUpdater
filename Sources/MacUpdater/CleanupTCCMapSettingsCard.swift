import AppKit
import MacUpdaterCore
import SwiftUI

/// The switch for the Files and Folders map (D10) in Porządki.
///
/// Off by default: the map needs Full Disk Access, and macOS gives that access to every program
/// Wega starts, not just to the scan's read of `TCC.db`. The card does not probe whether Wega has
/// it; the Files and Folders section says so after the next scan.
struct CleanupTCCMapSettingsCard: View {
    /// The Polish base text of the Full Disk Access warning, shown through `tr`.
    static let fullDiskAccessWarning = "Mapa wymaga Pełnego dostępu do dysku. macOS daje ten sam dostęp każdemu programowi, który Wega uruchamia: brew (także skryptom casków), npm (także skryptom pakietów), mas i powłoce, którą uruchamia „Odczytaj PATH”. Przyznaj go tylko na czas przeglądania mapy, a potem usuń Wegę z listy Pełny dostęp do dysku."

    @AppStorage(CleanupTCCMap.enabledKey)
    private var isEnabled = CleanupTCCMap.enabledByDefault

    var body: some View {
        WegaCard {
            VStack(alignment: .leading, spacing: 0) {
                WegaCardHeader(icon: "hand.raised", title: tr("Mapa wpisów „Pliki i foldery”"), titleTinted: true)

                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Narzędzie wiersza poleceń nie ma pakietu aplikacji, więc macOS zapisuje jego zgody w „Pliki i foldery” osobno dla każdej ścieżki, z której zostało uruchomione. Mapa przypisuje te wpisy do kopii, które znajdują Porządki: podczas skanu Wega odczytuje bazę zgód (TCC.db) i nigdy jej nie zmienia."))
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(tr(Self.fullDiskAccessWarning))
                        .font(.wega(.callout))
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: $isEnabled) {
                        Text(tr("Odczytuj mapę podczas skanu Porządków")).font(.wega(.callout))
                    }
                    .toggleStyle(.switch)

                    HStack(alignment: .firstTextBaseline) {
                        Text(tr("Czy Wega ma ten dostęp, pokaże dopiero następny skan Porządków."))
                            .font(.wega(.subheadline))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(tr("Otwórz Pełny dostęp do dysku")) {
                            NSWorkspace.shared.open(CleanupTCCMap.fullDiskAccessPaneURL)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(14)
            }
        }
    }
}
