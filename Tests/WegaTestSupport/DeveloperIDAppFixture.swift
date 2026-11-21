import Foundation
import Security

/// A Developer ID app installed in `/Applications` that has code the default
/// `SecStaticCodeCheckValidity` flags never hash: a slice of its universal main executable that
/// this Mac does not run, and a nested executable the bundle seals only by its code directory hash.
///
/// Choosing one reads signatures, `CodeResources` and Mach-O headers and hashes nothing.
public struct DeveloperIDApp: Sendable {
    /// Where to flip a byte that the default flags do not look at.
    public enum Tamper: Sendable {
        case sliceThisMacDoesNotRun
        case nestedCode
    }

    public enum Failure: Error, CustomStringConvertible {
        case unwritable(String)
        case outsideTheCopy(String)

        public var description: String {
            switch self {
            case let .unwritable(path): "could not flip a byte in \(path)"
            case let .outsideTheCopy(path): "\(path) does not resolve inside the copy, so it was left alone"
            }
        }
    }

    public let url: URL
    public let teamID: String
    /// The signature's identifier, which a requirement's `identifier` clause matches.
    public let signingIdentifier: String
    private let sealSize: Int
    private let foreignSliceByte: ByteLocation
    private let nestedCodeByte: ByteLocation

    /// Every qualifying app, smallest resource seal (`CodeResources`, in bytes) first, as a rough
    /// proxy for a quick validation. A linked app is left out: its copy would be the link.
    public static let installed: [DeveloperIDApp] = {
        let root = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let apps = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]
        )) ?? []
        return apps
            .filter { $0.pathExtension == "app" && !isSymbolicLink($0) }
            .compactMap(DeveloperIDApp.init(app:))
            .sorted { ($0.sealSize, $0.url.path) < ($1.sealSize, $1.url.path) }
    }()

    /// Clones the app into a fresh temporary directory and flips the one byte `tamper` names.
    /// On APFS the clone shares the original's blocks, so only the flipped block is copied.
    public func tamperedCopy(_ tamper: Tamper) throws -> TamperedAppCopy {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-tampered-app-\(UUID().uuidString)", isDirectory: true)
        let copy = TamperedAppCopy(url: root.appendingPathComponent(url.lastPathComponent), root: root)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: url, to: copy.url)
            let byte = tamper == .sliceThisMacDoesNotRun ? foreignSliceByte : nestedCodeByte
            try Self.flip(byte, in: copy.url, within: root)
        } catch {
            copy.remove()
            throw error
        }
        return copy
    }

    private init?(app: URL) {
        guard let signing = Self.developerIDSigning(of: app),
              let executable = Bundle(url: app)?.executableURL,
              let foreign = Self.byteInSlice(of: executable, inside: app, native: false),
              let nested = Self.nestedCodeByte(in: app),
              let seal = try? app.appendingPathComponent("Contents/_CodeSignature/CodeResources")
                  .resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        url = app
        teamID = signing.teamID
        signingIdentifier = signing.identifier
        sealSize = seal
        foreignSliceByte = foreign
        nestedCodeByte = nested
    }

    // MARK: - Signature

    private static func developerIDSigning(of app: URL) -> (teamID: String, identifier: String)? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let teamID = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String?,
              summary.hasPrefix("Developer ID Application:") else { return nil }
        return (teamID, identifier)
    }

    /// A byte in the executable of the first nested code `CodeResources` seals by `cdhash`: a
    /// nested bundle's executable or a signed Mach-O file. The default flags check only that the
    /// nested code directory hash is unchanged, not the pages it hashes.
    private static func nestedCodeByte(in app: URL) -> ByteLocation? {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let seal = contents.appendingPathComponent("_CodeSignature/CodeResources")
        guard let data = try? Data(contentsOf: seal),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let files = plist["files2"] as? [String: Any] else { return nil }
        let nested = files
            .filter { ($0.value as? [String: Any])?["cdhash"] != nil }
            .map(\.key)
            .sorted()
        for path in nested {
            let item = contents.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
            let executable = isDirectory.boolValue ? Bundle(url: item)?.executableURL : item
            if let executable, let byte = byteInSlice(of: executable, inside: app, native: true) {
                return byte
            }
        }
        return nil
    }

    // MARK: - Mach-O

    private struct ByteLocation: Sendable {
        /// Relative to the `.app`, so it names the same file in a copy.
        let path: String
        let offset: Int
    }

    private struct Slice {
        let cpuType: UInt32
        let offset: Int
    }

    #if arch(arm64)
    private static let nativeCPUType: UInt32 = 0x0100_000C // CPU_TYPE_ARM64
    #else
    private static let nativeCPUType: UInt32 = 0x0100_0007 // CPU_TYPE_X86_64
    #endif
    private static let machO64Magic = 0xFEED_FACF
    private static let codeSignatureCommand = 0x1D // LC_CODE_SIGNATURE
    private static let machO64HeaderSize = 32

    /// A hashed byte in a slice of `executable` that this Mac runs (`native`) or does not run.
    private static func byteInSlice(of executable: URL, inside app: URL, native: Bool) -> ByteLocation? {
        let appPath = app.resolvingSymlinksInPath().path + "/"
        let filePath = executable.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(appPath), let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }
        for slice in slices(in: handle) where (slice.cpuType == nativeCPUType) == native {
            if let offset = hashedByte(in: slice, of: handle) {
                return ByteLocation(path: String(filePath.dropFirst(appPath.count)), offset: offset)
            }
        }
        return nil
    }

    private static func slices(in handle: FileHandle) -> [Slice] {
        guard (try? handle.seek(toOffset: 0)) != nil,
              let header = try? handle.read(upToCount: 4096), header.count >= 8 else { return [] }
        let bytes = [UInt8](header)
        let magic = bigEndian(bytes, 0, 4)
        guard magic == 0xCAFE_BABE || magic == 0xCAFE_BABF else {
            guard littleEndian(bytes, 0) == machO64Magic else { return [] }
            return [Slice(cpuType: UInt32(littleEndian(bytes, 4)), offset: 0)]
        }
        let wide = magic == 0xCAFE_BABF
        let entrySize = wide ? 32 : 20
        let count = bigEndian(bytes, 4, 4)
        guard count > 0, count < 16, 8 + count * entrySize <= bytes.count else { return [] }
        return (0 ..< count).map { index in
            let entry = 8 + index * entrySize
            return Slice(
                cpuType: UInt32(bigEndian(bytes, entry, 4)),
                offset: wide ? bigEndian(bytes, entry + 8, 8) : bigEndian(bytes, entry + 8, 4)
            )
        }
    }

    /// The byte halfway between the end of the slice's load commands and its code signature. The
    /// code directory hashes every byte before the signature, and nothing that has to be parsed
    /// lies there. The middle of the whole slice would not do: an Electron launcher's slice is
    /// about half signature, and the signature's padding is not hashed.
    private static func hashedByte(in slice: Slice, of handle: FileHandle) -> Int? {
        guard (try? handle.seek(toOffset: UInt64(slice.offset))) != nil,
              let header = try? handle.read(upToCount: machO64HeaderSize), header.count == machO64HeaderSize,
              littleEndian([UInt8](header), 0) == machO64Magic else { return nil }
        let commandsSize = littleEndian([UInt8](header), 20)
        guard commandsSize > 0, commandsSize < 1 << 20,
              let read = try? handle.read(upToCount: commandsSize), read.count == commandsSize else { return nil }
        let commands = [UInt8](read)
        let codeStart = machO64HeaderSize + commandsSize
        var cursor = 0
        while cursor + 16 <= commands.count {
            let size = littleEndian(commands, cursor + 4)
            if littleEndian(commands, cursor) == codeSignatureCommand {
                let signatureStart = littleEndian(commands, cursor + 8)
                return signatureStart > codeStart ? slice.offset + (codeStart + signatureStart) / 2 : nil
            }
            guard size >= 8 else { return nil }
            cursor += size
        }
        return nil
    }

    private static func bigEndian(_ bytes: [UInt8], _ start: Int, _ count: Int) -> Int {
        bytes[start ..< start + count].reduce(0) { $0 << 8 | Int($1) }
    }

    private static func littleEndian(_ bytes: [UInt8], _ start: Int) -> Int {
        bytes[start ..< start + 4].reversed().reduce(0) { $0 << 8 | Int($1) }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? true
    }

    /// Writes only to a regular file that resolves inside `root`, the directory this copy was made
    /// in, so no link can lead the write back to the installed original.
    private static func flip(_ byte: ByteLocation, in app: URL, within root: URL) throws {
        let file = app.appendingPathComponent(byte.path)
        guard !isSymbolicLink(file),
              file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw Failure.outsideTheCopy(byte.path)
        }
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0o555
        try FileManager.default.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: file.path)
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(byte.offset))
        guard let original = try handle.read(upToCount: 1)?.first else { throw Failure.unwritable(byte.path) }
        try handle.seek(toOffset: UInt64(byte.offset))
        try handle.write(contentsOf: [original ^ 0xFF])
    }
}

/// A tampered clone of a ``DeveloperIDApp``.
public struct TamperedAppCopy: Sendable {
    public let url: URL
    fileprivate let root: URL

    public func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
