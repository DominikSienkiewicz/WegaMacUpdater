import Darwin
import Foundation
import WegaHelperKit

/// A component PKG may describe an installed application in its top-level PackageInfo.
/// Only the app's exact identity, version and Developer ID publisher can confirm the hint.
enum OldInstallerVersionEvidence {
    private struct DeclaredApp {
        let url: URL
        let id: String
        let version: String
    }

    private static let timeout = ProcessTimeoutPolicy(deadline: 1, idle: 1)
    private static let maxXMLBytes = 32 * 1024

    static func installedVersion(at pinnedFile: URL) -> String? {
        guard let metadata = packageInfo(in: pinnedFile),
              let signature = try? BoundedProcess.run(SystemPaths.pkgutil, arguments: ["--check-signature", pinnedFile.path], timeouts: timeout),
              signature.exitCode == 0, let team = leafTeam(in: signature.standardOutput) else { return nil }
        return confirmedVersion(packageInfo: metadata, packageTeam: team, applications: SystemPaths.applicationsDirectory,
                                matchesPublisher: { app, identifier, team in
            let requirement = CodeSignatureVerifier.teamIDRequirement(teamID: team, bundleID: identifier)
            let result = try? BoundedProcess.run(URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--strict", "-R=" + requirement, app.path], timeouts: timeout)
            return result?.exitCode == 0
        })
    }

    static func packageInfo(in file: URL) -> String? {
        guard let metadata = try? BoundedProcess.run(URL(fileURLWithPath: "/usr/bin/bsdtar"), arguments: [
            "-xOqf", file.path, "--", "PackageInfo"
        ], timeouts: timeout), metadata.exitCode == 0, metadata.standardOutput.utf8.count <= maxXMLBytes else { return nil }
        return metadata.standardOutput
    }

    static func leafTeam(in signature: String) -> String? {
        let lines = signature.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains("Status: signed by a developer certificate issued by Apple for distribution") else { return nil }
        for line in lines {
            guard line.hasPrefix("1. Developer ID Installer: "),
                  let match = line.range(of: #"\([A-Z0-9]{10}\)$"#, options: .regularExpression) else { continue }
            return String(line[match].dropFirst().dropLast())
        }
        return nil
    }

    static func confirmedVersion(packageInfo: String, packageTeam: String, applications: URL,
                                 matchesPublisher: (URL, String, String) -> Bool) -> String? {
        guard packageInfo.utf8.count <= maxXMLBytes, !packageInfo.contains("<!"),
              let doc = try? XMLDocument(xmlString: packageInfo, options: .nodeLoadExternalEntitiesNever),
              let root = doc.rootElement(), root.name == "pkg-info",
              let location = root.attribute(forName: "install-location")?.stringValue,
              location == "/" || location == "/Applications" else { return nil }

        let bundles = root.elements(forName: "bundle-version").flatMap { $0.elements(forName: "bundle") }
        let candidates = bundles.compactMap { bundle -> DeclaredApp? in
            guard let path = bundle.attribute(forName: "path")?.stringValue,
                  let name = appName(path: path, location: location),
                  let id = bundle.attribute(forName: "id")?.stringValue, MigrationPlanner.isSafeBundleID(id),
                  let version = bundle.attribute(forName: "CFBundleShortVersionString")?.stringValue,
                  !version.isEmpty, version.utf8.count <= 64, version.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return DeclaredApp(url: applications.appending(component: name, directoryHint: .isDirectory), id: id, version: version)
        }
        guard candidates.count == 1, let app = candidates.first,
              let info = bundleInfo(at: app.url), info["CFBundleIdentifier"] as? String == app.id,
              info["CFBundleShortVersionString"] as? String == app.version, matchesPublisher(app.url, app.id, packageTeam) else { return nil }
        return app.version
    }

    private static func appName(path: String, location: String) -> String? {
        var parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.first == "." { parts.removeFirst() }
        if location == "/" {
            guard parts.first == "Applications" else { return nil }
            parts.removeFirst()
        }
        guard parts.count == 1, let leaf = parts.first, !leaf.hasPrefix("."), leaf.hasSuffix(".app"),
              !leaf.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "/" }) else { return nil }
        return String(leaf)
    }

    private static func bundleInfo(at app: URL) -> [String: Any]? {
        let plist = app.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        let fd = Darwin.open(plist.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var status = stat()
        let limit = 1024 * 1024
        guard Darwin.fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
