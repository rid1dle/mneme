import Foundation
import SQLite3

/// Everything Mneme keeps: one SQLite file plus content-addressed blob and thumbnail folders.
/// Ids are UUIDs, every row has `updated_at`, deletions are markers: sync can be added later without migrating.
/// Not thread-safe: the app uses one Store from one serial queue only (hence `@unchecked Sendable`).
public final class Store: @unchecked Sendable {
    public let directory: URL
    public let blobs: URL
    public let thumbs: URL
    /// Set when the store file was unreadable and was moved aside to this path.
    public private(set) var recoveredFrom: URL?
    let db: Database

    static let fileName = "mneme.sqlite"

    /// Opens the store. A damaged file is moved aside (with its Blobs and Thumbs, so nothing in it is lost) and a fresh
    /// store starts; any other failure (locked, disk full) throws and leaves everything where it is.
    public init(directory: URL, busyTimeoutMs: Int32 = 3_000) throws {
        let fm = FileManager.default
        self.directory = directory
        blobs = directory.appendingPathComponent("Blobs", isDirectory: true)
        thumbs = directory.appendingPathComponent("Thumbs", isDirectory: true)
        for d in [directory, blobs, thumbs] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let file = directory.appendingPathComponent(Store.fileName)
        do {
            db = try Store.open(file, busyTimeoutMs: busyTimeoutMs)
        } catch let error as DBError where error.isCorruption {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let moved = directory.appendingPathComponent("\(Store.fileName).broken-\(f.string(from: Date()))")
            try fm.moveItem(at: file, to: moved)
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: file.path + suffix)
                if fm.fileExists(atPath: side.path) { try? fm.moveItem(at: side, to: URL(fileURLWithPath: moved.path + suffix)) }
            }
            for (folder, name) in [(blobs, "Blobs"), (thumbs, "Thumbs")] {
                try? fm.moveItem(at: folder, to: URL(fileURLWithPath: moved.path + "-" + name))
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            recoveredFrom = moved
            db = try Store.open(file, busyTimeoutMs: busyTimeoutMs)
        }
    }

    private static func open(_ file: URL, busyTimeoutMs: Int32) throws -> Database {
        let db = try Database(path: file.path, busyTimeoutMs: busyTimeoutMs)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;")
        var ok = ""
        try db.query("PRAGMA quick_check") { ok = $0.text(0) ?? "" }
        guard ok == "ok" else { throw DBError.sqlite("quick_check: \(ok)", code: SQLITE_CORRUPT) }
        try db.exec("""
        CREATE TABLE IF NOT EXISTS items(
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT, text TEXT, preview TEXT NOT NULL,
            hash TEXT NOT NULL, byte_size INTEGER NOT NULL, source_bundle TEXT, source_name TEXT,
            file_urls TEXT, link_title TEXT, link_image TEXT, ocr_text TEXT, ocr_done INTEGER NOT NULL DEFAULT 0,
            thumb TEXT, width INTEGER, height INTEGER,
            created_at REAL NOT NULL, updated_at REAL NOT NULL, last_used_at REAL NOT NULL,
            in_history INTEGER NOT NULL DEFAULT 1, deleted_at REAL, char_count INTEGER NOT NULL DEFAULT 0, search_id INTEGER);
        CREATE UNIQUE INDEX IF NOT EXISTS items_hash ON items(hash) WHERE deleted_at IS NULL;
        CREATE INDEX IF NOT EXISTS items_history ON items(in_history, deleted_at, last_used_at DESC);
        CREATE TABLE IF NOT EXISTS representations(
            item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE, ord INTEGER NOT NULL,
            item_index INTEGER NOT NULL, type TEXT NOT NULL, inline BLOB, blob TEXT, size INTEGER NOT NULL,
            PRIMARY KEY(item_id, ord));
        CREATE INDEX IF NOT EXISTS representations_blob ON representations(blob) WHERE blob IS NOT NULL;
        CREATE TABLE IF NOT EXISTS pinboards(
            id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL, sort INTEGER NOT NULL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL, deleted_at REAL);
        CREATE TABLE IF NOT EXISTS pins(
            pinboard_id TEXT NOT NULL REFERENCES pinboards(id) ON DELETE CASCADE,
            item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
            added_at REAL NOT NULL, position REAL NOT NULL DEFAULT 0, PRIMARY KEY(pinboard_id, item_id));
        CREATE INDEX IF NOT EXISTS pins_item ON pins(item_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(item_id UNINDEXED, body, tokenize='unicode61 remove_diacritics 2');
        """)
        try migrate(db)
        return db
    }

    static let schemaVersion = 3

    /// Brings a store made by an earlier version up to date. Version 2: pins have a position (pinboards keep the
    /// order the user drags them into); existing pins keep their pinned-at order.
    private static func migrate(_ db: Database) throws {
        let version = try db.scalarInt("PRAGMA user_version") ?? 0
        guard version < schemaVersion else { return }
        var columns = Set<String>()
        try db.query("PRAGMA table_info(pins)") { columns.insert($0.text(1) ?? "") }
        if !columns.contains("position") {
            try db.exec("ALTER TABLE pins ADD COLUMN position REAL NOT NULL DEFAULT 0; UPDATE pins SET position = added_at;")
        }
        // Version 3: search rows are numbered by items.search_id, so removing one is a direct lookup, not a scan.
        var itemColumns = Set<String>()
        try db.query("PRAGMA table_info(items)") { itemColumns.insert($0.text(1) ?? "") }
        try db.transaction {
            if !itemColumns.contains("search_id") { try db.exec("ALTER TABLE items ADD COLUMN search_id INTEGER") }
            try db.exec("""
                UPDATE items SET search_id = rowid WHERE search_id IS NULL;
                CREATE UNIQUE INDEX IF NOT EXISTS items_search ON items(search_id);
                DELETE FROM items_fts;
                INSERT INTO items_fts(rowid, item_id, body)
                    SELECT search_id, id, \(searchBody) FROM items WHERE deleted_at IS NULL AND length(\(searchBody)) > 0;
                CREATE INDEX IF NOT EXISTS pins_order ON pins(pinboard_id, position DESC);
                PRAGMA user_version = \(schemaVersion);
                """)
        }
    }

    /// Search body: title, text, text read from the image, link title and source app, one per line.
    static let searchBody = "concat_ws(char(10), title, text, ocr_text, link_title, source_name)"

}
