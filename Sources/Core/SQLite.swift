import Foundation
import SQLite3

public enum DBError: Error, CustomStringConvertible {
    case sqlite(String, code: Int32 = 0)
    public var description: String { if case .sqlite(let m, let c) = self { return "\(m) (\(c))" }; return "" }
    public var code: Int32 { if case .sqlite(_, let c) = self { return c & 0xFF }; return 0 }
    /// The file is not a database or is damaged (as opposed to locked, full or unreadable for now).
    public var isCorruption: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One row while a query steps; read columns by index.
public struct Row {
    let stmt: OpaquePointer
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: double(i)) }
    public func optionalDate(_ i: Int32) -> Date? { isNull(i) ? nil : date(i) }
    public func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
    public func uuid(_ i: Int32) -> UUID? { text(i).flatMap(UUID.init(uuidString:)) }
    public func blob(_ i: Int32) -> Data? {
        guard !isNull(i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
}

/// A thin wrapper over one SQLite connection with a statement cache. Not thread-safe: one owner at a time.
public final class Database {
    let handle: OpaquePointer
    private var cache: [String: OpaquePointer] = [:]

    public init(path: String, busyTimeoutMs: Int32 = 3_000) throws {
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let h else {
            if let h { sqlite3_close(h) }
            throw DBError.sqlite("cannot open \(path)", code: SQLITE_CANTOPEN)
        }
        handle = h
        sqlite3_busy_timeout(handle, busyTimeoutMs)
    }

    deinit {
        for s in cache.values { sqlite3_finalize(s) }
        sqlite3_close(handle)
    }

    private var message: String { String(cString: sqlite3_errmsg(handle)) }
    private var code: Int32 { sqlite3_errcode(handle) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? message
            sqlite3_free(err)
            throw DBError.sqlite(msg, code: code)
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        let stmt: OpaquePointer
        if let s = cache[sql] {
            stmt = s
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        } else {
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let s else { throw DBError.sqlite("\(message) in: \(sql)", code: code) }
            cache[sql] = s
            stmt = s
        }
        for (n, arg) in args.enumerated() {
            let i = Int32(n + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, i)
            case let v as Int: sqlite3_bind_int64(stmt, i, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, i, v)
            case let v as Bool: sqlite3_bind_int64(stmt, i, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, i, v)
            case let v as Date: sqlite3_bind_double(stmt, i, v.timeIntervalSince1970)
            case let v as UUID: sqlite3_bind_text(stmt, i, v.uuidString, -1, SQLITE_TRANSIENT)
            case let v as String: sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            default: throw DBError.sqlite("cannot bind \(type(of: arg!))")
            }
        }
        return stmt
    }

    public func run(_ sql: String, _ args: [Any?] = []) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_reset(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError.sqlite("\(message) in: \(sql)", code: code) }
    }

    public func query(_ sql: String, _ args: [Any?] = [], row: (Row) throws -> Void) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_reset(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw DBError.sqlite("\(message) in: \(sql)", code: code) }
            try row(Row(stmt: stmt))
        }
    }

    public func scalarInt(_ sql: String, _ args: [Any?] = []) throws -> Int? {
        var v: Int?
        try query(sql, args) { v = $0.isNull(0) ? nil : $0.int(0) }
        return v
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let v = try body()
            try exec("COMMIT")
            return v
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
