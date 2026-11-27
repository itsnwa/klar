import Foundation
import SQLite3

/// A connection to a SQLite database, through the system's libsqlite3.
///
/// Not thread-safe on its own: its owner uses it from one serial queue (or
/// the main actor).
/// Statements are prepared once per SQL string and kept until `close()`.
nonisolated final class SQLiteDatabase {
    struct Error: Swift.Error, CustomStringConvertible {
        let code: Int32
        let message: String

        var description: String { "SQLite error \(code): \(message)" }
    }

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// Opens the database at `url`, creating it if needed, in WAL mode. A new
    /// database returns deleted pages to the file system when the owner runs
    /// `PRAGMA incremental_vacuum` (auto_vacuum can only be set before the
    /// file is first written, and switching to WAL writes it).
    init(url: URL) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(handle)
            throw Error(code: result, message: message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 2000)
        try execute("PRAGMA auto_vacuum = INCREMENTAL; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
    }

    /// A read-only database in memory, from a copy of a database file's
    /// bytes, which never touches the disk. A WAL database's header must say
    /// it isn't one (bytes 18 and 19 set to 1), or nothing opens.
    init(deserializing bytes: Data) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(handle)
            throw Error(code: result, message: message)
        }
        self.handle = handle
        guard let buffer = sqlite3_malloc64(UInt64(bytes.count))?.assumingMemoryBound(to: UInt8.self) else {
            throw Error(code: SQLITE_NOMEM, message: "out of memory")
        }
        bytes.copyBytes(to: buffer, count: bytes.count)
        // SQLite frees the buffer with the connection, or at once if this fails
        let size = sqlite3_int64(bytes.count)
        try check(sqlite3_deserialize(handle, "main", buffer, size, size,
                                      UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY)))
    }

    deinit {
        close()
    }

    func close() {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        statements = [:]
        sqlite3_close_v2(handle)
        handle = nil
    }

    // MARK: - Running SQL

    /// Runs one or more statements without bindings or results (schema, pragmas).
    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    /// Runs a statement for its effect; returns how many rows it changed.
    @discardableResult
    func run(_ sql: String, _ values: SQLiteValue?...) throws -> Int {
        try run(sql, values)
    }

    @discardableResult
    func run(_ sql: String, _ values: [SQLiteValue?]) throws -> Int {
        let statement = try prepared(sql, values)
        defer { finish(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            result = sqlite3_step(statement)
        }
        try check(result, done: SQLITE_DONE)
        return Int(sqlite3_changes(handle))
    }

    /// Runs a query, mapping each row (rows mapped to nil are left out).
    func query<T>(_ sql: String, _ values: SQLiteValue?..., row map: (SQLiteRow) -> T?) throws -> [T] {
        try query(sql, values, row: map)
    }

    func query<T>(_ sql: String, _ values: [SQLiteValue?], row map: (SQLiteRow) -> T?) throws -> [T] {
        let statement = try prepared(sql, values)
        defer { finish(statement) }
        var rows: [T] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let row = map(SQLiteRow(statement: statement)) {
                rows.append(row)
            }
            result = sqlite3_step(statement)
        }
        try check(result, done: SQLITE_DONE)
        return rows
    }

    /// Runs `body` in a transaction, rolled back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// The schema version the owner has migrated to (`PRAGMA user_version`).
    func userVersion() throws -> Int {
        try query("PRAGMA user_version") { $0.int(0) }.first ?? 0
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    // MARK: - Statements

    private func prepared(_ sql: String, _ values: [SQLiteValue?]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            try check(sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil))
            guard let prepared else { throw Error(code: SQLITE_MISUSE, message: "empty statement: \(sql)") }
            statements[sql] = prepared
            statement = prepared
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result = value?.bind(to: statement, at: index) ?? sqlite3_bind_null(statement, index)
            if result != SQLITE_OK {
                finish(statement)
                try check(result)
            }
        }
        return statement
    }

    private func finish(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func check(_ result: Int32, done: Int32 = SQLITE_OK) throws {
        guard result != done else { return }
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
        throw Error(code: result, message: message)
    }
}

/// A value bound to a statement's parameter.
nonisolated protocol SQLiteValue {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32
}

/// Has SQLite copy the bytes, so the Swift string needn't outlive the call.
nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated extension String: SQLiteValue {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_text(statement, index, self, -1, SQLITE_TRANSIENT)
    }
}

nonisolated extension Int: SQLiteValue {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_int64(statement, index, Int64(self))
    }
}

nonisolated extension Double: SQLiteValue {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_double(statement, index, self)
    }
}

nonisolated extension Data: SQLiteValue {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        guard !isEmpty else { return sqlite3_bind_zeroblob(statement, index, 0) }
        return withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        }
    }
}

/// Seconds since 2001 (`timeIntervalSinceReferenceDate`), as Core Data stored dates.
nonisolated extension Date: SQLiteValue {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_double(statement, index, timeIntervalSinceReferenceDate)
    }
}

/// The current row of a query, read by column index.
nonisolated struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    func string(_ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func data(_ column: Int32) -> Data? {
        guard !isNull(column) else { return nil }
        // The pointer first, then its length (SQLite's documented order).
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    func date(_ column: Int32) -> Date? {
        isNull(column) ? nil : Date(timeIntervalSinceReferenceDate: double(column))
    }
}
