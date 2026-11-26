import SwiftUI
import MacUpdaterCore

struct InventoryFootprintCell: View {
    let footprint: InventoryFootprint?
    @State private var showsDetails = false

    var body: some View {
        if let footprint {
            Button { showsDetails = true } label: {
                Text(formatted(footprint.totalBytes))
                    .lineLimit(1)
            }
            .buttonStyle(.link)
            .font(.wega(.subheadline))
            .help(tr("Pokaż składniki rozmiaru"))
            .accessibilityHint(tr("Pokaż składniki rozmiaru"))
            .popover(isPresented: $showsDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(tr("Pakiet aplikacji"), value: formatted(footprint.bundleBytes))
                    if footprint.includesLibrary {
                        LabeledContent(tr("Pamięć podręczna"), value: formatted(footprint.cacheBytes))
                        LabeledContent(tr("Dane użytkownika"), value: formatted(footprint.dataBytes))
                    } else {
                        Text(tr("Do tej instalacji można przypisać tylko pakiet aplikacji."))
                            .font(.wega(.footnote))
                    }
                }
                .padding()
            }
        } else {
            Text("—").foregroundStyle(.quaternary)
        }
    }

    private func formatted(_ bytes: Int64?) -> String {
        guard let bytes else { return tr("rozmiar nieznany") }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
