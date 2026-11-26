import SwiftUI
import MacUpdaterCore

struct InventoryFootprintCell: View {
    let footprint: InventoryFootprint?
    let change: InventoryFootprintChange?
    let showingGrowth: Bool
    @State private var showsDetails = false

    var body: some View {
        if let footprint {
            Button { showsDetails = true } label: {
                Text(showingGrowth ? delta(change?.totalBytes) : formatted(footprint.totalBytes))
                    .lineLimit(1)
            }
            .buttonStyle(.link)
            .font(.wega(.subheadline))
            .help(tr("Pokaż składniki rozmiaru"))
            .accessibilityHint(tr("Pokaż składniki rozmiaru"))
            .popover(isPresented: $showsDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(tr("Pakiet aplikacji"), value: component(footprint.bundleBytes, change?.bundleBytes))
                    if footprint.includesLibrary {
                        LabeledContent(tr("Pamięć podręczna"), value: component(footprint.cacheBytes, change?.cacheBytes))
                        LabeledContent(tr("Dane użytkownika"), value: component(footprint.dataBytes, change?.dataBytes))
                    } else {
                        Text(tr("Do tej instalacji można przypisać tylko pakiet aplikacji."))
                            .font(.wega(.footnote))
                    }
                    if showingGrowth && change?.totalBytes == nil {
                        Text(tr("Brak porównywalnego pomiaru łącznego rozmiaru.")).font(.wega(.footnote))
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

    private func delta(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        if bytes == 0 { return "0 B" }
        return (bytes > 0 ? "+" : "−") + formatted(abs(bytes))
    }

    private func component(_ bytes: Int64?, _ change: Int64?) -> String {
        showingGrowth ? "\(formatted(bytes)) (\(delta(change)))" : formatted(bytes)
    }
}
