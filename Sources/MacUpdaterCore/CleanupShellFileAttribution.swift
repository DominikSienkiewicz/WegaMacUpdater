import Foundation

/// Finds the shell file and line that adds a `PATH` entry. The files are read once, through the
/// injected (guarded) file system; only `file:line` leaves the type. The text is kept only until the
/// value is released and is hidden from every description and reflection.
public struct CleanupShellFileAttribution: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let maximumFileBytes = 262_144

    private struct ShellFile: Sendable {
        let path: String
        let lines: [[Unicode.Scalar]]
    }

    private static let zshFiles = ["zshenv", "zprofile", "zshrc", "zlogin"]
    private static let bashSystemFiles = ["profile", "bashrc"]
    private static let bashHomeFiles = [".bash_profile", ".bash_login", ".profile", ".bashrc"]
    private static let leadingBoundaries: Set<Unicode.Scalar> = [" ", "\t", "=", ":", "\"", "'", "("]
    private static let trailingBoundaries: Set<Unicode.Scalar> = ["/", ":", "\"", "'", " ", "\t", ";", ")", "}"]

    /// Paths the guard refused while reading.
    public let skippedProtected: [String]
    private let files: [ShellFile]
    private let home: [String]

    /// Reads the files for `shell` (`zsh`, `bash`; anything else only the `paths` files) once.
    public init(shell: String?, home: URL, systemConfigurationDirectory: URL, fileSystem: CleanupFileSystem) {
        self.home = CleanupPathText.components(of: home.path)
        var candidates: [URL] = []
        func system(_ name: String) -> URL { systemConfigurationDirectory.appending(path: name, directoryHint: .notDirectory) }
        func personal(_ name: String) -> URL { home.appending(path: name, directoryHint: .notDirectory) }
        switch shell {
        case "zsh":
            candidates = Self.zshFiles.map(system) + Self.zshFiles.map { personal("." + $0) }
        case "bash":
            candidates = Self.bashSystemFiles.map(system) + Self.bashHomeFiles.map(personal)
        default:
            break
        }
        var skipped: [String] = []
        candidates.append(system("paths"))
        var read: [ShellFile] = []
        for url in candidates {
            Self.read(url, fileSystem: fileSystem, into: &read, skipped: &skipped)
        }
        let pathsDirectory = system("paths.d")
        do {
            for child in try fileSystem.contents(of: pathsDirectory) where child.kind == .file || child.kind == .symlink {
                Self.read(child.url, fileSystem: fileSystem, into: &read, skipped: &skipped)
            }
        } catch CleanupFileSystemError.protectedLocation(let refused) {
            skipped.append(refused)
        } catch {
            // An unreadable directory contributes no files.
        }
        files = read
        skippedProtected = skipped
    }

    private static func read(_ url: URL, fileSystem: CleanupFileSystem, into files: inout [ShellFile], skipped: inout [String]) {
        do {
            let text = try fileSystem.readText(url, maxBytes: maximumFileBytes)
            files.append(ShellFile(path: url.path, lines: lines(of: text)))
        } catch CleanupFileSystemError.protectedLocation(let refused) {
            if !skipped.contains(refused) { skipped.append(refused) }
        } catch {
            // A missing, oversized or unreadable file is not evidence either way.
        }
    }

    /// Split on `\n` over scalars, because `"\r\n"` is a single Character; a trailing `\r` is dropped.
    private static func lines(of text: String) -> [[Unicode.Scalar]] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var scalars = Array(line)
            if scalars.last == "\r" { scalars.removeLast() }
            return scalars
        }
    }

    public func locations(of entry: String) -> [CleanupShellFileLocation] {
        let spellings = spellings(of: entry)
        var found: [CleanupShellFileLocation] = []
        for file in files {
            for (offset, line) in file.lines.enumerated()
            where !Self.isComment(line) && spellings.contains(where: { Self.contains($0, in: line) }) {
                found.append(CleanupShellFileLocation(file: file.path, line: offset + 1))
            }
        }
        return found
    }

    private func spellings(of entry: String) -> [[Unicode.Scalar]] {
        var trimmed = Array(entry.unicodeScalars)
        while trimmed.count > 1, trimmed.last == "/" { trimmed.removeLast() }
        let absolute = String(String.UnicodeScalarView(trimmed))
        var texts = [absolute]
        let components = CleanupPathText.components(of: absolute)
        if CleanupPathText.isAbsolute(absolute), components.starts(with: home) {
            let rest = components.dropFirst(home.count).joined(separator: "/")
            for prefix in ["~", "$HOME", "${HOME}"] {
                texts.append(rest.isEmpty ? prefix : prefix + "/" + rest)
            }
        }
        return texts.map { Array($0.unicodeScalars) }
    }

    private static func isComment(_ line: [Unicode.Scalar]) -> Bool {
        line.first { $0 != " " && $0 != "\t" } == "#"
    }

    private static func contains(_ needle: [Unicode.Scalar], in line: [Unicode.Scalar]) -> Bool {
        guard !needle.isEmpty, line.count >= needle.count else { return false }
        for start in 0...(line.count - needle.count) where line[start..<(start + needle.count)].elementsEqual(needle) {
            let end = start + needle.count
            let leadingOK = start == 0 || leadingBoundaries.contains(line[start - 1])
            let trailingOK = end == line.count || trailingBoundaries.contains(line[end])
            if leadingOK, trailingOK { return true }
        }
        return false
    }

    public var description: String {
        "CleanupShellFileAttribution(files: \(files.count))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["files": files.count], displayStyle: .struct)
    }
}
