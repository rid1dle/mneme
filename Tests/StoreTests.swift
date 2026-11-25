import Foundation

let storeTests: [TestCase] = [
    test("should create the tables and the search index in a new directory") {
        let store = try makeStore()
        let names = try tableNames(store)
        for t in ["items", "representations", "pinboards", "pins", "items_fts"] { expect(names.contains(t), "missing \(t)") }
        var isDir: ObjCBool = false
        expect(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("Blobs").path, isDirectory: &isDir) && isDir.boolValue)
        expect(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("Thumbs").path, isDirectory: &isDir) && isDir.boolValue)
        expect(store.recoveredFrom == nil)
    },
    test("should keep pinboards across reopening the store") {
        let dir = makeSandbox().appendingPathComponent("store")
        let id = UUID()
        do {
            let store = try Store(directory: dir)
            try store.db.run("INSERT INTO pinboards(id, name, color, sort, created_at, updated_at) VALUES (?,?,?,?,?,?)",
                             [id, "Work", "#3A70C8", 2, Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 200)])
        }
        let reopened = try Store(directory: dir)
        var rows: [(String, String, String, Int)] = []
        try reopened.db.query("SELECT id, name, color, sort FROM pinboards") { rows.append(($0.text(0)!, $0.text(1)!, $0.text(2)!, $0.int(3))) }
        expectEqual(rows.count, 1)
        expectEqual(rows.first?.0, id.uuidString)
        expectEqual(rows.first?.1, "Work")
        expectEqual(rows.first?.2, "#3A70C8")
        expectEqual(rows.first?.3, 2)
    },
    test("should add the pin order to a store made by an earlier version") {
        let dir = makeSandbox().appendingPathComponent("store")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let db = try Database(path: dir.appendingPathComponent("mneme.sqlite").path)
            try db.exec("""
                CREATE TABLE pins(pinboard_id TEXT NOT NULL, item_id TEXT NOT NULL, added_at REAL NOT NULL, PRIMARY KEY(pinboard_id, item_id));
                INSERT INTO pins VALUES ('b', 'i1', 100), ('b', 'i2', 200);
                PRAGMA user_version = 1;
                """)
        }
        let store = try Store(directory: dir)
        var rows: [String] = []
        try store.db.query("SELECT item_id FROM pins ORDER BY position DESC") { rows.append($0.text(0)!) }
        expectEqual(rows, ["i2", "i1"])
        expectEqual(try store.db.scalarInt("PRAGMA user_version"), Store.schemaVersion)
    },
    test("should move a broken store file aside and open a fresh one") {
        let dir = makeSandbox().appendingPathComponent("store")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("mneme.sqlite").path, contents: Data(repeating: 7, count: 4096))
        let store = try Store(directory: dir)
        let moved = store.recoveredFrom
        expect(moved?.lastPathComponent.hasPrefix("mneme.sqlite.broken-") == true, "got \(String(describing: moved))")
        expect(moved.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        let names = try tableNames(store)
        expect(names.contains("items"))
    },
]
