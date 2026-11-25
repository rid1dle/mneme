import Foundation

public struct Query: Equatable, Sendable {
    public var text = ""
    public var kinds: Set<ItemKind> = []
    public var sourceBundleID: String?
    public var since: Date?
    /// nil = History.
    public var pinboard: UUID?
    public init() {}
}

/// An FTS5 match expression that searches the typed words literally: each word quoted (quotes doubled), all words
/// required, the last one matched by its start. Words with no letter or digit are dropped. nil when nothing is left.
public func ftsMatch(_ text: String) -> String? {
    let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    guard !words.isEmpty else { return nil }
    return words.enumerated().map { n, w in
        "\"" + w.replacingOccurrences(of: "\"", with: "\"\"") + "\"" + (n == words.count - 1 ? "*" : "")
    }.joined(separator: " ")
}

/// Page listings leave out the stored text; a card needs only the preview, and `item(_:)` loads the rest.
let pageColumns = itemColumns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .map { $0 == "text" ? "NULL" : "i.\($0)" }.joined(separator: ", ")

extension Store {
    public func page(_ q: Query, offset: Int, limit: Int) throws -> [Item] {
        var sql = "SELECT \(pageColumns) FROM items i"
        var args: [Any?] = []
        var conditions = ["i.deleted_at IS NULL"]
        let order: String
        if let board = q.pinboard {
            sql += " JOIN pins p ON p.item_id = i.id AND p.pinboard_id = ?"
            args.append(board)
            order = "p.position DESC, i.id"
        } else {
            conditions.append("i.in_history = 1")
            order = "i.last_used_at DESC, i.id"
        }
        if !q.kinds.isEmpty {
            conditions.append("i.kind IN (\(Array(repeating: "?", count: q.kinds.count).joined(separator: ",")))")
            args += q.kinds.map(\.rawValue).sorted()
        }
        if let app = q.sourceBundleID { conditions.append("i.source_bundle = ?"); args.append(app) }
        if let since = q.since { conditions.append("i.last_used_at >= ?"); args.append(since) }
        if let match = ftsMatch(q.text) {
            conditions.append("i.search_id IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)")
            args.append(match)
        }
        sql += " WHERE " + conditions.joined(separator: " AND ") + " ORDER BY \(order) LIMIT ? OFFSET ?"
        args += [limit, offset]
        var items: [Item] = []
        try db.query(sql, args) { items.append(decodeItem($0)) }
        return items
    }

    public func sourceApps() throws -> [SourceApp] {
        var apps: [SourceApp] = []
        try db.query("""
            SELECT source_bundle, MAX(source_name) FROM items WHERE deleted_at IS NULL AND source_bundle IS NOT NULL
            GROUP BY source_bundle ORDER BY COUNT(*) DESC, MAX(source_name)
            """) { apps.append(SourceApp(bundleID: $0.text(0)!, name: $0.text(1) ?? $0.text(0)!)) }
        return apps
    }
}
