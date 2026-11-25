import Foundation

/// Representations up to this size live in the database; larger ones are files in `Blobs/`.
let inlineLimit = 64 * 1024
/// `items.text` keeps this many characters for search and display; the whole text stays in the representations.
let storedTextLimit = 100_000

let itemColumns = """
id, kind, title, text, preview, hash, byte_size, source_bundle, source_name, file_urls, link_title, link_image,
ocr_text, thumb, width, height, created_at, updated_at, last_used_at, in_history, deleted_at, char_count
"""

func decodeItem(_ r: Row) -> Item {
    let urls = r.text(9).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }?
        .compactMap(URL.init(string:)) ?? []
    let source = r.text(7).map { SourceApp(bundleID: $0, name: r.text(8) ?? $0) }
    return Item(id: r.uuid(0)!, kind: ItemKind(rawValue: r.text(1) ?? "") ?? .text, title: r.text(2), text: r.text(3),
                preview: r.text(4) ?? "", hash: r.text(5) ?? "", byteSize: r.int(6), charCount: r.int(21), source: source, fileURLs: urls,
                linkTitle: r.text(10), linkImage: r.text(11), ocrText: r.text(12), thumb: r.text(13),
                width: r.isNull(14) ? nil : r.int(14), height: r.isNull(15) ? nil : r.int(15),
                createdAt: r.date(16), updatedAt: r.date(17), lastUsedAt: r.date(18), inHistory: r.int(19) == 1,
                deletedAt: r.optionalDate(20))
}

extension Store {
    // MARK: items

    /// Adds a copy to the front of History. Content already in the store (same hash) is moved to the front instead.
    @discardableResult
    public func ingest(_ c: Capture, now: Date) throws -> Item {
        if let existing = try liveID(hash: c.hash) {
            try db.run("UPDATE items SET in_history = 1, last_used_at = ?, updated_at = ? WHERE id = ?", [now, now, existing])
            return try item(existing)!
        }
        let id = UUID()
        let stored = try writeBlobs(c.representations, hash: c.hash)
        let urls = String(data: try JSONEncoder().encode(c.fileURLs.map(\.absoluteString)), encoding: .utf8)
        try db.transaction {
            try db.run("""
                INSERT INTO items(id, kind, text, preview, hash, byte_size, char_count, source_bundle, source_name, file_urls,
                                  created_at, updated_at, last_used_at, in_history, search_id)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,1, (SELECT COALESCE(MAX(search_id), 0) + 1 FROM items))
                """, [id, c.kind.rawValue, c.text.map { String($0.prefix(storedTextLimit)) }, c.preview, c.hash, c.byteSize, c.text?.count ?? 0,
                      c.source?.bundleID, c.source?.name, c.fileURLs.isEmpty ? nil : urls, now, now, now])
            try insertRepresentations(id, stored)
            try refreshSearch(id)
        }
        return try item(id)!
    }

    public func item(_ id: UUID) throws -> Item? {
        var found: Item?
        try db.query("SELECT \(itemColumns) FROM items WHERE id = ? AND deleted_at IS NULL", [id]) { found = decodeItem($0) }
        return found
    }

    public func representations(_ id: UUID) throws -> [Representation] {
        var reps: [Representation] = []
        try db.query("SELECT item_index, type, inline, blob FROM representations WHERE item_id = ? ORDER BY ord", [id]) { r in
            let data = try r.blob(2) ?? r.text(3).map { try Data(contentsOf: blobs.appendingPathComponent($0)) } ?? Data()
            reps.append(Representation(index: r.int(0), type: r.text(1) ?? "", data: data))
        }
        return reps
    }

    /// Pasting an item puts it back at the front of History.
    public func markUsed(_ id: UUID, now: Date) throws {
        try db.run("UPDATE items SET in_history = 1, last_used_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL", [now, now, id])
    }

    public func removeFromHistory(_ id: UUID, now: Date) throws {
        try db.transaction {
            try db.run("UPDATE items SET in_history = 0, updated_at = ? WHERE id = ?", [now, id])
            if try !isPinned(id) { try tombstone(id, now: now) }
        }
    }

    public func deleteEverywhere(_ id: UUID, now: Date) throws {
        try db.transaction { try tombstone(id, now: now) }
    }

    public func rename(_ id: UUID, title: String?, now: Date) throws {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.transaction {
            try db.run("UPDATE items SET title = ?, updated_at = ? WHERE id = ?", [t?.isEmpty == false ? t : nil, now, id])
            try refreshSearch(id)
        }
    }

    /// Replaces the item's content, keeping its id. With `rtf` the item stays rich text (plain text kept beside it);
    /// without, it becomes plain text. Other old types (HTML) are dropped because they no longer match.
    public func editText(_ id: UUID, text: String, rtf: Data? = nil, now: Date) throws {
        var reps = [Representation(type: PasteType.plain, data: Data(text.utf8))]
        if let rtf { reps.append(Representation(type: PasteType.rtf, data: rtf)) }
        try replaceContent(id, reps, now: now, update: """
            kind = COALESCE(?, CASE WHEN kind = 'richText' THEN 'text' ELSE kind END), text = ?, preview = ?, char_count = ?
            """, [rtf != nil ? ItemKind.richText.rawValue : nil, String(text.prefix(storedTextLimit)),
                  String(text.prefix(previewLength)), text.count])
    }

    /// Replaces an image with its edited version (saved from Preview). The thumbnail and the text read from it are
    /// cleared so both are made again; pins and History stay.
    public func replaceImage(_ id: UUID, png: Data, now: Date) throws {
        try replaceContent(id, [Representation(type: PasteType.png, data: png)], now: now, update: """
            thumb = NULL, width = NULL, height = NULL, ocr_text = NULL, ocr_done = 0, file_urls = NULL
            """, [])
    }

    private func replaceContent(_ id: UUID, _ reps: [Representation], now: Date, update: String, _ args: [Any?]) throws {
        var hash = contentHash(reps)
        if let other = try liveID(hash: hash), other != id { hash += ":" + id.uuidString }
        let stored = try writeBlobs(reps, hash: hash)
        try db.transaction {
            try db.run("DELETE FROM representations WHERE item_id = ?", [id])
            try db.run("UPDATE items SET \(update), hash = ?, byte_size = ?, updated_at = ? WHERE id = ?",
                       args + [hash, reps.reduce(0) { $0 + $1.data.count }, now, id])
            try insertRepresentations(id, stored)
            try refreshSearch(id)
        }
    }

    public func clearHistory(now: Date) throws {
        try db.transaction {
            var ids: [UUID] = []
            try db.query("SELECT id FROM items WHERE in_history = 1 AND deleted_at IS NULL") { ids.append($0.uuid(0)!) }
            for id in ids {
                try db.run("UPDATE items SET in_history = 0, updated_at = ? WHERE id = ?", [now, id])
                if try !isPinned(id) { try tombstone(id, now: now) }
            }
        }
    }

    public func setThumb(_ id: UUID, name: String, width: Int, height: Int) throws {
        try db.run("UPDATE items SET thumb = ?, width = ?, height = ? WHERE id = ?", [name, width, height, id])
    }

    public func setLinkPreview(_ id: UUID, title: String?, image: String?) throws {
        try db.transaction {
            try db.run("UPDATE items SET link_title = ?, link_image = ? WHERE id = ?", [title, image, id])
            try refreshSearch(id)
        }
    }

    public func setOCRText(_ id: UUID, text: String) throws {
        try db.transaction {
            try db.run("UPDATE items SET ocr_text = ?, ocr_done = 1 WHERE id = ?", [text.isEmpty ? nil : text, id])
            try refreshSearch(id)
        }
    }

    public func pendingOCR(limit: Int) throws -> [Item] {
        var items: [Item] = []
        try db.query("""
            SELECT \(itemColumns) FROM items WHERE kind = 'image' AND ocr_done = 0 AND deleted_at IS NULL
            ORDER BY last_used_at DESC LIMIT ?
            """, [limit]) { items.append(decodeItem($0)) }
        return items
    }

    // MARK: pinboards

    public func createPinboard(name: String, color: String, now: Date) throws -> Pinboard {
        let order = (try db.scalarInt("SELECT MAX(sort) FROM pinboards WHERE deleted_at IS NULL") ?? -1) + 1
        let board = Pinboard(id: UUID(), name: name, color: color, order: order, createdAt: now, updatedAt: now, deletedAt: nil)
        try db.run("INSERT INTO pinboards(id, name, color, sort, created_at, updated_at) VALUES (?,?,?,?,?,?)",
                   [board.id, name, color, order, now, now])
        return board
    }

    public func allPinboards() throws -> [Pinboard] {
        var boards: [Pinboard] = []
        try db.query("SELECT id, name, color, sort, created_at, updated_at FROM pinboards WHERE deleted_at IS NULL ORDER BY sort") { r in
            boards.append(Pinboard(id: r.uuid(0)!, name: r.text(1) ?? "", color: r.text(2) ?? "#888888", order: r.int(3),
                                   createdAt: r.date(4), updatedAt: r.date(5), deletedAt: nil))
        }
        return boards
    }

    public func renamePinboard(_ id: UUID, name: String, now: Date) throws {
        try db.run("UPDATE pinboards SET name = ?, updated_at = ? WHERE id = ?", [name, now, id])
    }

    public func recolorPinboard(_ id: UUID, color: String, now: Date) throws {
        try db.run("UPDATE pinboards SET color = ?, updated_at = ? WHERE id = ?", [color, now, id])
    }

    public func movePinboard(_ id: UUID, to index: Int, now: Date = Date()) throws {
        var ids = try allPinboards().map(\.id)
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        ids.insert(id, at: min(max(index, 0), ids.count))
        try db.transaction {
            for (n, b) in ids.enumerated() { try db.run("UPDATE pinboards SET sort = ?, updated_at = ? WHERE id = ? AND sort != ?", [n, now, b, n]) }
        }
    }

    /// Deletes the pinboard; its items stay in History, and items in neither are deleted.
    public func deletePinboard(_ id: UUID, now: Date) throws {
        try db.transaction {
            var members: [UUID] = []
            try db.query("SELECT item_id FROM pins WHERE pinboard_id = ?", [id]) { members.append($0.uuid(0)!) }
            try db.run("DELETE FROM pins WHERE pinboard_id = ?", [id])
            try db.run("UPDATE pinboards SET deleted_at = ?, updated_at = ? WHERE id = ?", [now, now, id])
            for m in members where try !isPinned(m) && !inHistory(m) { try tombstone(m, now: now) }
        }
    }

    public func pin(_ id: UUID, to board: UUID, now: Date) throws {
        try db.run("""
            INSERT OR IGNORE INTO pins(pinboard_id, item_id, added_at, position)
            VALUES (?, ?, ?, (SELECT COALESCE(MAX(position), 0) + 1 FROM pins WHERE pinboard_id = ?))
            """, [board, id, now, board])
        try db.run("UPDATE items SET updated_at = ? WHERE id = ?", [now, id])
    }

    /// Moves a pinned item to `index` (0 = first) in its pinboard's order.
    public func movePinned(_ id: UUID, in board: UUID, to index: Int, now: Date) throws {
        var ids: [UUID] = []
        try db.query("SELECT item_id FROM pins WHERE pinboard_id = ? ORDER BY position DESC", [board]) { ids.append($0.uuid(0)!) }
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        ids.insert(id, at: min(max(index, 0), ids.count))
        try db.transaction {
            for (n, item) in ids.enumerated() {
                try db.run("UPDATE pins SET position = ? WHERE pinboard_id = ? AND item_id = ?", [Double(ids.count - n), board, item])
            }
            try db.run("UPDATE pinboards SET updated_at = ? WHERE id = ?", [now, board])
        }
    }

    public func unpin(_ id: UUID, from board: UUID, now: Date) throws {
        try db.transaction {
            try db.run("DELETE FROM pins WHERE pinboard_id = ? AND item_id = ?", [board, id])
            try db.run("UPDATE items SET updated_at = ? WHERE id = ?", [now, id])
            if try !isPinned(id) && !inHistory(id) { try tombstone(id, now: now) }
        }
    }

    public func pinboards(of id: UUID) throws -> [UUID] {
        var ids: [UUID] = []
        try db.query("""
            SELECT p.pinboard_id FROM pins p JOIN pinboards b ON b.id = p.pinboard_id
            WHERE p.item_id = ? AND b.deleted_at IS NULL ORDER BY b.sort
            """, [id]) { ids.append($0.uuid(0)!) }
        return ids
    }

    // MARK: internals

    func liveID(hash: String) throws -> UUID? {
        var id: UUID?
        try db.query("SELECT id FROM items WHERE hash = ? AND deleted_at IS NULL", [hash]) { id = $0.uuid(0) }
        return id
    }

    func isPinned(_ id: UUID) throws -> Bool { (try db.scalarInt("SELECT 1 FROM pins WHERE item_id = ? LIMIT 1", [id])) != nil }

    func inHistory(_ id: UUID) throws -> Bool { (try db.scalarInt("SELECT in_history FROM items WHERE id = ?", [id])) == 1 }

    /// Keeps only the id, kind, hash and times (a deletion marker); drops the content, pins and search entry.
    /// Blob files are removed by the next retention pass.
    func tombstone(_ id: UUID, now: Date) throws {
        try db.run("DELETE FROM pins WHERE item_id = ?", [id])
        try db.run("DELETE FROM representations WHERE item_id = ?", [id])
        try db.run("DELETE FROM items_fts WHERE rowid = (SELECT search_id FROM items WHERE id = ?)", [id])
        try db.run("""
            UPDATE items SET deleted_at = ?, updated_at = ?, in_history = 0, title = NULL, text = NULL, preview = '',
                ocr_text = NULL, link_title = NULL, file_urls = NULL WHERE id = ?
            """, [now, now, id])
    }

    private enum StoredData { case inline(Data), blob(String, Int) }

    private func writeBlobs(_ reps: [Representation], hash: String) throws -> [(Representation, StoredData)] {
        try reps.enumerated().map { ord, r in
            guard r.data.count > inlineLimit else { return (r, .inline(r.data)) }
            let name = "\(hash.replacingOccurrences(of: ":", with: "-"))-\(ord)"
            let url = blobs.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { try r.data.write(to: url, options: .atomic) }
            return (r, .blob(name, r.data.count))
        }
    }

    private func insertRepresentations(_ id: UUID, _ stored: [(Representation, StoredData)]) throws {
        for (ord, (r, s)) in stored.enumerated() {
            switch s {
            case .inline(let d):
                try db.run("INSERT INTO representations(item_id, ord, item_index, type, inline, size) VALUES (?,?,?,?,?,?)",
                           [id, ord, r.index, r.type, d, d.count])
            case .blob(let name, let size):
                try db.run("INSERT INTO representations(item_id, ord, item_index, type, blob, size) VALUES (?,?,?,?,?,?)",
                           [id, ord, r.index, r.type, name, size])
            }
        }
    }

    /// Rewrites the item's search row (see `Store.searchBody`); found by number, not by scanning.
    func refreshSearch(_ id: UUID) throws {
        try db.run("DELETE FROM items_fts WHERE rowid = (SELECT search_id FROM items WHERE id = ?)", [id])
        try db.run("""
            INSERT INTO items_fts(rowid, item_id, body)
            SELECT search_id, id, \(Store.searchBody) FROM items
            WHERE id = ? AND deleted_at IS NULL AND length(\(Store.searchBody)) > 0
            """, [id])
    }
}
