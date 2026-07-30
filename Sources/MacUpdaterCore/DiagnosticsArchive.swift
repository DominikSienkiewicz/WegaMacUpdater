import Foundation

/// One file inside a diagnostics archive.
public struct DiagnosticsArchiveEntry: Equatable, Sendable {
    /// Path inside the archive, e.g. `logs/wega.log`. Always `/`-separated.
    public let name: String
    public let contents: Data

    public init(name: String, contents: Data) {
        self.name = name
        self.contents = contents
    }

    public init(name: String, text: String) {
        self.init(name: name, contents: Data(text.utf8))
    }

    public var text: String? { String(data: contents, encoding: .utf8) }
}

/// OBS-02 — writes a ZIP archive in memory, stored (uncompressed), with no dependency
/// on Foundation's file-coordination zip or on an external `ditto`.
///
/// Deliberately pure `Data` in / `Data` out: the acceptance criterion for a diagnostics
/// bundle is "the archive contains these entries", and that is a claim a unit test should
/// be able to make without a temp directory, a save panel or a subprocess. `Deflate` is
/// omitted on purpose — a diagnostics bundle is a handful of text files, the archive is
/// still a valid ZIP every unarchiver opens, and stored entries keep this writer small
/// enough to read in one sitting.
public enum DiagnosticsArchive {

    /// Builds the archive bytes for `entries`, in the order given.
    ///
    /// - Parameter modifiedAt: the timestamp stamped on every entry. Passed in rather than
    ///   read from the clock so the same input always produces the same bytes.
    public static func zip(_ entries: [DiagnosticsArchiveEntry], modifiedAt: Date) -> Data {
        let (dosTime, dosDate) = dosTimestamp(modifiedAt)
        var payload = Data()
        var directory = Data()

        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.contents)
            let offset = UInt32(payload.count)

            payload.appendUInt32(0x0403_4b50)      // local file header
            payload.appendUInt16(20)               // version needed
            payload.appendUInt16(0x0800)           // UTF-8 names
            payload.appendUInt16(0)                // stored
            payload.appendUInt16(dosTime)
            payload.appendUInt16(dosDate)
            payload.appendUInt32(crc)
            payload.appendUInt32(UInt32(entry.contents.count))
            payload.appendUInt32(UInt32(entry.contents.count))
            payload.appendUInt16(UInt16(name.count))
            payload.appendUInt16(0)                // no extra field
            payload.append(name)
            payload.append(entry.contents)

            directory.appendUInt32(0x0201_4b50)    // central directory header
            directory.appendUInt16(20)             // version made by
            directory.appendUInt16(20)             // version needed
            directory.appendUInt16(0x0800)
            directory.appendUInt16(0)
            directory.appendUInt16(dosTime)
            directory.appendUInt16(dosDate)
            directory.appendUInt32(crc)
            directory.appendUInt32(UInt32(entry.contents.count))
            directory.appendUInt32(UInt32(entry.contents.count))
            directory.appendUInt16(UInt16(name.count))
            directory.appendUInt16(0)              // extra
            directory.appendUInt16(0)              // comment
            directory.appendUInt16(0)              // disk number
            directory.appendUInt16(0)              // internal attributes
            directory.appendUInt32(0o100_600 << 16) // external attributes: 0600 regular file
            directory.appendUInt32(offset)
            directory.append(name)
        }

        let directoryOffset = UInt32(payload.count)
        var out = payload
        out.append(directory)
        out.appendUInt32(0x0605_4b50)              // end of central directory
        out.appendUInt16(0)
        out.appendUInt16(0)
        out.appendUInt16(UInt16(entries.count))
        out.appendUInt16(UInt16(entries.count))
        out.appendUInt32(UInt32(directory.count))
        out.appendUInt32(directoryOffset)
        out.appendUInt16(0)                        // no archive comment
        return out
    }

    /// The entry names a written archive advertises in its central directory. Used by the
    /// regression tests to assert the bundle's contents against the real bytes rather than
    /// against the array that produced them.
    public static func entryNames(inZip data: Data) -> [String] {
        var names: [String] = []
        var index = 0
        let bytes = [UInt8](data)
        while index + 46 <= bytes.count {
            guard bytes[index] == 0x50, bytes[index + 1] == 0x4b,
                  bytes[index + 2] == 0x01, bytes[index + 3] == 0x02 else {
                index += 1
                continue
            }
            let nameLength = Int(bytes[index + 28]) | Int(bytes[index + 29]) << 8
            let extraLength = Int(bytes[index + 30]) | Int(bytes[index + 31]) << 8
            let commentLength = Int(bytes[index + 32]) | Int(bytes[index + 33]) << 8
            let nameStart = index + 46
            guard nameStart + nameLength <= bytes.count else { break }
            names.append(String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self))
            index = nameStart + nameLength + extraLength + commentLength
        }
        return names
    }

    // MARK: - Primitives

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// MS-DOS packed time/date, the only timestamp a classic ZIP header carries.
    /// Dates before 1980 are clamped — the format cannot express them.
    static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, parts.year ?? 1980)
        let hourBits: Int = (parts.hour ?? 0) << 11
        let minuteBits: Int = (parts.minute ?? 0) << 5
        let secondBits: Int = (parts.second ?? 0) / 2
        let time = UInt16(hourBits | minuteBits | secondBits)
        let packedDate = UInt16((year - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, packedDate)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
