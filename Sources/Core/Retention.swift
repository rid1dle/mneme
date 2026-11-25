import Foundation

public struct RetentionReport: Equatable {
    public var leftHistory = 0
    public var deleted = 0
    public var blobsRemoved = 0
    public var tombstonesPurged = 0
    public init(leftHistory: Int = 0, deleted: Int = 0, blobsRemoved: Int = 0, tombstonesPurged: Int = 0) {
        self.leftHistory = leftHistory; self.deleted = deleted; self.blobsRemoved = blobsRemoved; self.tombstonesPurged = tombstonesPurged
    }
}

/// Deletion markers are kept this long (for sync later), then the rows go.
let tombstoneLifetime: TimeInterval = 30 * 86_400

extension Store {
    /// History entries last used before `now - maxAge` leave History (`nil` keeps them forever); items then in neither
    /// History nor a pinboard are deleted; old deletion markers are purged; unreferenced blob and thumbnail files go.
    public func applyRetention(maxAge: TimeInterval?, now: Date) throws -> RetentionReport {
        var report = RetentionReport()
        try db.transaction {
            if let maxAge {
                var expired: [UUID] = []
                try db.query("SELECT id FROM items WHERE in_history = 1 AND deleted_at IS NULL AND last_used_at < ?",
                             [now.addingTimeInterval(-maxAge)]) { expired.append($0.uuid(0)!) }
                for id in expired {
                    try db.run("UPDATE items SET in_history = 0, updated_at = ? WHERE id = ?", [now, id])
                    if try !isPinned(id) { try tombstone(id, now: now); report.deleted += 1 }
                }
                report.leftHistory = expired.count
            }
            try db.run("DELETE FROM items WHERE deleted_at IS NOT NULL AND deleted_at < ?", [now.addingTimeInterval(-tombstoneLifetime)])
            report.tombstonesPurged = db.changes
        }
        var used = Set<String>()
        try db.query("SELECT blob FROM representations WHERE blob IS NOT NULL") { used.insert($0.text(0)!) }
        try db.query("SELECT link_image FROM items WHERE link_image IS NOT NULL AND deleted_at IS NULL") { used.insert($0.text(0)!) }
        report.blobsRemoved = removeFiles(in: blobs, except: used)
        var thumbsUsed = Set<String>()
        try db.query("SELECT thumb FROM items WHERE thumb IS NOT NULL AND deleted_at IS NULL") { thumbsUsed.insert($0.text(0)!) }
        _ = removeFiles(in: thumbs, except: thumbsUsed)
        return report
    }

    private func removeFiles(in dir: URL, except keep: Set<String>) -> Int {
        let fm = FileManager.default
        var removed = 0
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(name) {
            if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}
