import Foundation

func makeStore() throws -> Store { try Store(directory: makeSandbox().appendingPathComponent("store")) }

func tableNames(_ store: Store) throws -> Set<String> {
    var names = Set<String>()
    try store.db.query("SELECT name FROM sqlite_master WHERE type IN ('table','view')") { names.insert($0.text(0) ?? "") }
    return names
}

let finder = SourceApp(bundleID: "com.apple.finder", name: "Finder")

func textCapture(_ s: String, source: SourceApp? = finder) -> Capture {
    guard case .success(let c) = classify(PasteboardSnapshot(changeCount: 1, types: [PasteType.plain], items: [[PasteType.plain: Data(s.utf8)]]),
                                          source: source, rules: CaptureRules()) else { fatalError("not capturable: \(s)") }
    return c
}

func imageCapture(bytes: Int, fill: UInt8) -> Capture {
    guard case .success(let c) = classify(PasteboardSnapshot(changeCount: 1, types: [PasteType.png], items: [[PasteType.png: Data(repeating: fill, count: bytes)]]),
                                          source: finder, rules: CaptureRules()) else { fatalError() }
    return c
}

func day(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + n * 86_400) }

func blobFiles(_ store: Store) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: store.blobs.path))?.sorted() ?? []
}

func ftsBody(_ store: Store, _ id: UUID) throws -> String? {
    var body: String?
    try store.db.query("SELECT body FROM items_fts WHERE item_id = ?", [id]) { body = $0.text(0) }
    return body
}

extension Store {
    func historyIDs() throws -> [UUID] {
        var ids: [UUID] = []
        try db.query("SELECT id FROM items WHERE in_history = 1 AND deleted_at IS NULL ORDER BY last_used_at DESC") { ids.append($0.uuid(0)!) }
        return ids
    }
}

/// Inserts `count` text items straight into the store in one transaction (fast setup for large-store tests).
func bulkInsert(_ store: Store, count: Int, start: Date = day(0)) throws {
    try store.db.transaction {
        for n in 0..<count {
            let id = UUID()
            let t = start.addingTimeInterval(Double(n))
            try store.db.run("""
                INSERT INTO items(id, kind, text, preview, hash, byte_size, source_bundle, source_name, created_at, updated_at, last_used_at, search_id)
                VALUES (?, 'text', ?, ?, ?, 10, 'com.apple.finder', 'Finder', ?, ?, ?, (SELECT COALESCE(MAX(search_id), 0) + 1 FROM items))
                """, [id, "bulk item \(n)", "bulk item \(n)", "bulk-\(n)", t, t, t])
            try store.refreshSearch(id)
        }
    }
}
