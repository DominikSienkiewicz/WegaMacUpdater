import Foundation
import WegaHelperKit

/// The Java runtimes installed on this Mac, scanned into the same ``ApplicationInfo`` every
/// other row is built from.
///
/// A JDK is a bundle like every app Wega already tracks, but it is a `.jdk` under
/// `/Library/Java/JavaVirtualMachines` — and both halves of the ordinary scan reject it:
/// ``ApplicationScanner`` keeps only `pathExtension == "app"`, and ``AppScanDirectories``
/// only ever descends from the two Applications roots. So an installed, outdated,
/// Homebrew-packaged JDK (`temurin`, `temurin@21`, …) was invisible to every checker in the
/// app, with nothing anywhere reporting it. This scanner is the missing discovery half; the
/// version comparison is then the ordinary cask check, reached through
/// ``CaskPackageReceiptIndex``.
public struct JavaRuntimeScanner: Sendable {
    /// The one bundle extension accepted here. JDKs, JREs and Oracle's `.jdk` layout all
    /// use it; anything else in the directory (an installer leftover, a stray folder) is
    /// not a runtime and is skipped.
    public static let bundleExtension = "jdk"

    public init() {}

    /// The directories macOS JDK installers write to: the system-wide one every `.pkg`
    /// uses, plus the per-user location some tool-managed runtimes prefer.
    public static func scanDirectories() -> [URL] {
        [
            SystemPaths.javaVirtualMachinesDirectory,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Java/JavaVirtualMachines", isDirectory: true),
        ]
    }

    /// Every runtime found across `directories`, deduplicated by path so a symlinked
    /// directory cannot list the same JDK twice.
    public func scanAll(directories: [URL] = JavaRuntimeScanner.scanDirectories()) -> [ApplicationInfo] {
        var seen = Set<String>()
        return directories.flatMap { scan(in: $0) }.filter { seen.insert($0.id).inserted }
    }

    public func scan(in directory: URL) -> [ApplicationInfo] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension == Self.bundleExtension }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map(runtimeInfo(for:))
    }

    private func runtimeInfo(for bundleURL: URL) -> ApplicationInfo {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let infoDict = (try? Data(contentsOf: infoPlistURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            ?? [:]
        let resourceValues = try? bundleURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])

        return ApplicationInfo(
            path: bundleURL,
            name: bundleURL.lastPathComponent,
            bundleIdentifier: infoDict["CFBundleIdentifier"] as? String,
            version: JavaRuntimeBundle.version(fromInfoDictionary: infoDict),
            // Deliberately nil. A JDK's `CFBundleVersion` is the *build* number on its own
            // (Temurin 26.0.1 ships `8`), so handing it to the version comparators — which
            // read `buildVersion` as an alternative spelling of the release — would compare
            // `8` against a cask's `26.0.2`.
            buildVersion: nil,
            installDate: resourceValues?.creationDate,
            updateDate: resourceValues?.contentModificationDate,
            isManagedByBrew: false
        )
    }
}

/// Reads the release version out of a JDK bundle's `Info.plist`.
///
/// Kept separate from the scanner (and free of IO) because the two keys disagree often
/// enough to be worth testing on their own: `CFBundleShortVersionString` is the release for
/// Temurin and Zulu, while some runtimes leave it out and publish the version only inside
/// the `JavaVM` dictionary.
public enum JavaRuntimeBundle {
    public static func version(fromInfoDictionary infoDict: [String: Any]) -> String? {
        if let short = infoDict["CFBundleShortVersionString"] as? String, !short.isEmpty {
            return short
        }
        guard let javaVM = infoDict["JavaVM"] as? [String: Any] else { return nil }
        for key in ["JVMVersion", "JVMPlatformVersion"] {
            if let value = javaVM[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
