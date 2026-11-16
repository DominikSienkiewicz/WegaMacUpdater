import Foundation
import SQLite3

public struct CleanupTCCRow: Equatable, Sendable {
    public let service: String
    public let client: String
    public let clientType: Int
    public let authValue: Int

    public init(service: String, client: String, clientType: Int, authValue: Int) {
        self.service = service
        self.client = client
        self.clientType = clientType
        self.authValue = authValue
    }
}

public enum CleanupTCCDatabaseError: Error, Equatable {
    case unreadable
    case unsupportedSchema
}

public protocol CleanupTCCDatabaseReading: Sendable {
    var fileURL: URL { get }
    func rows(for services: [CleanupTCCService]) throws -> [CleanupTCCRow]
}

public struct SQLiteCleanupTCCDatabase: CleanupTCCDatabaseReading {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(home: URL) {
        self.fileURL = home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db", directoryHint: .notDirectory)
    }

    public func rows(for services: [CleanupTCCService]) throws -> [CleanupTCCRow] {
        guard !services.isEmpty else { return [] }
        var handle: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let target = URL(filePath: fileURL.path, directoryHint: .notDirectory).absoluteString + "?mode=ro"
        guard sqlite3_open_v2(target, &handle, openFlags, nil) == SQLITE_OK, let connection = handle else {
            sqlite3_close_v2(handle)
            throw CleanupTCCDatabaseError.unreadable
        }
        defer { sqlite3_close_v2(connection) }
        try requireSupportedSchema(in: connection)
        return try readRows(for: services, in: connection)
    }

    private static let requiredColumns: Set<String> = ["service", "client", "client_type", "auth_value"]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func requireSupportedSchema(in connection: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA table_info(access)", -1, &statement, nil) == SQLITE_OK
        else {
            sqlite3_finalize(statement)
            throw CleanupTCCDatabaseError.unreadable
        }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            if let name = Self.text(statement, column: 1) { columns.insert(name) }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw CleanupTCCDatabaseError.unreadable }
        guard Self.requiredColumns.isSubset(of: columns) else { throw CleanupTCCDatabaseError.unsupportedSchema }
    }

    private func readRows(for services: [CleanupTCCService], in connection: OpaquePointer) throws -> [CleanupTCCRow] {
        let placeholders = Array(repeating: "?", count: services.count).joined(separator: ", ")
        let query = "SELECT service, client, client_type, auth_value FROM access WHERE service IN (\(placeholders))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw CleanupTCCDatabaseError.unreadable
        }
        defer { sqlite3_finalize(statement) }
        for (offset, service) in services.enumerated() {
            let bound = sqlite3_bind_text(statement, Int32(offset + 1), service.rawValue, -1, Self.transient)
            guard bound == SQLITE_OK else { throw CleanupTCCDatabaseError.unreadable }
        }
        var rows: [CleanupTCCRow] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            if let row = Self.row(from: statement) { rows.append(row) }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw CleanupTCCDatabaseError.unreadable }
        return rows
    }

    /// A row is kept only when every column is present and the text columns hold no NUL byte,
    /// which `String(cString:)` would silently cut off.
    private static func row(from statement: OpaquePointer?) -> CleanupTCCRow? {
        guard sqlite3_column_type(statement, 2) != SQLITE_NULL,
              sqlite3_column_type(statement, 3) != SQLITE_NULL,
              let service = text(statement, column: 0),
              let client = text(statement, column: 1) else { return nil }
        return CleanupTCCRow(
            service: service,
            client: client,
            clientType: Int(sqlite3_column_int64(statement, 2)),
            authValue: Int(sqlite3_column_int64(statement, 3))
        )
    }

    private static func text(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, column))
        guard strlen(UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self)) == length else { return nil }
        return String(cString: pointer)
    }
}
