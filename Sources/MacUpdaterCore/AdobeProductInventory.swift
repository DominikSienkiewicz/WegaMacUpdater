import Foundation
import WegaHelperKit

/// One Adobe product Creative Cloud has installed, as Creative Cloud itself records it.
public struct AdobeInstalledProduct: Equatable, Sendable {
    /// Adobe's four-to-six letter product code — `LRCC` for Lightroom, `PHSP` for Photoshop.
    /// The only key the product catalog is addressable by.
    public var sapCode: String
    public var version: String
    /// The product's own name (`Lightroom`), which is a prefix-or-substring of the installed
    /// bundle's name (`Adobe Lightroom`) rather than equal to it.
    public var productName: String

    public init(sapCode: String, version: String, productName: String) {
        self.sapCode = sapCode
        self.version = version
        self.productName = productName
    }
}

/// Which Adobe products are installed, read from Creative Cloud's own uninstall records.
///
/// An Adobe app's bundle says nothing about which product it is in Adobe's catalog: the
/// `Info.plist` carries a bundle id (`com.adobe.lightroomCC`) and a version, and no SAP code
/// anywhere. Creative Cloud writes one `.adbarg` argument file per installed product, and
/// that file names the SAP code, the version and the product name together — so the mapping
/// is read off the machine instead of maintained as a hand-written table that goes stale
/// every time Adobe ships a product Wega has not heard of.
public enum AdobeProductInventory {
    /// Parses one `.adbarg` file: `--key=value` lines, one per line.
    public static func parse(argumentFile text: String) -> AdobeInstalledProduct? {
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("--"), let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.index(line.startIndex, offsetBy: 2)..<separator])
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let sapCode = fields["sapCode"], !sapCode.isEmpty,
              let version = fields["productVersion"], !version.isEmpty else { return nil }
        return AdobeInstalledProduct(
            sapCode: sapCode,
            version: version,
            productName: fields["productName"] ?? sapCode
        )
    }

    /// Every product recorded in `directory`. A machine without Creative Cloud has no such
    /// directory, which reads as "no Adobe products" rather than as an error.
    public static func installedProducts(
        in directory: URL = SystemPaths.adobeUninstallDirectory,
        fileManager: FileManager = .default
    ) -> [AdobeInstalledProduct] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension == "adbarg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return parse(argumentFile: text)
            }
    }

    /// The product an installed bundle is a copy of, or `nil` when nothing in the inventory
    /// describes it.
    ///
    /// Both halves of the rule are load-bearing. The **version must match exactly**: that is
    /// what tells the two Lightrooms apart, since `Lightroom` (LRCC 9.4.1) and
    /// `Lightroom Classic` (LTRM, a wholly different version line) are both plausible names
    /// for a bundle called "Adobe Lightroom". The **name must be contained** in the bundle's
    /// name, because Adobe records `Lightroom` for a bundle called `Adobe Lightroom`. Where
    /// several products still qualify, the longest product name wins — the most specific
    /// record, so `Lightroom Classic` is never beaten by the `Lightroom` that is a substring
    /// of it.
    public static func product(
        matching app: ApplicationInfo,
        in inventory: [AdobeInstalledProduct]
    ) -> AdobeInstalledProduct? {
        guard let installed = app.version, !installed.isEmpty else { return nil }
        let appName = StringNormalizer.normalize(app.name)
        return inventory
            .filter { product in
                guard versionsEqual(product.version, installed) else { return false }
                let productName = StringNormalizer.normalize(product.productName)
                return !productName.isEmpty && appName.contains(productName)
            }
            .max { $0.productName.count < $1.productName.count }
    }
}
