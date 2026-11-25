import AppKit
import Carbon.HIToolbox
import Foundation

private func scratch() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("mneme-tests-\(UUID().uuidString)")) }

let reviewFixTests: [TestCase] = [
    // C1
    test("should never delete a card while ⌫ is held down to clear the search") {
        var g = DeleteKeyGuard()
        expect(!g.allows(isRepeat: false, searchEmpty: false))   // press starts with text: it edits the search
        expect(!g.allows(isRepeat: true, searchEmpty: true))     // text gone, key still repeating
        expect(!g.allows(isRepeat: true, searchEmpty: true))
        expect(g.allows(isRepeat: false, searchEmpty: true))     // a new press on an empty search removes
        expect(!g.allows(isRepeat: true, searchEmpty: true))     // and holding it removes nothing more
    },
    // I2
    test("should clear 5,000 items from History in under 3 seconds") {
        let s = try makeStore()
        try bulkInsert(s, count: 5_000)
        let start = Date()
        try s.clearHistory(now: day(1))
        let seconds = Date().timeIntervalSince(start)
        expect(seconds < 3, "took \(seconds) s")
        expectEqual(try s.db.scalarInt("SELECT COUNT(*) FROM items_fts"), 0)
    },
    test("should find and forget items through their search rows after an upgrade from version 2") {
        let dir = makeSandbox().appendingPathComponent("store")
        var id = UUID()
        do {
            let s = try Store(directory: dir)
            id = try s.ingest(textCapture("upgrade me please"), now: day(0)).id
            try s.db.exec("DELETE FROM items_fts; INSERT INTO items_fts(rowid, item_id, body) VALUES (999, '\(id.uuidString)', 'upgrade me please'); PRAGMA user_version = 2;")
        }
        let s = try Store(directory: dir)
        var q = Query(); q.text = "upgrade"
        expectEqual(try s.page(q, offset: 0, limit: 5).map(\.id), [id])
        try s.deleteEverywhere(id, now: day(1))
        expectEqual(try s.db.scalarInt("SELECT COUNT(*) FROM items_fts"), 0)
    },
    // I6
    test("should not move the store aside when another program only has it locked") {
        let dir = makeSandbox().appendingPathComponent("store")
        let id: UUID
        do { id = try Store(directory: dir).ingest(textCapture("keep me"), now: day(0)).id }
        let other = try Database(path: dir.appendingPathComponent("mneme.sqlite").path)
        try other.exec("PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE")
        var threw = false
        do { _ = try Store(directory: dir, busyTimeoutMs: 200) } catch { threw = true }
        try other.exec("ROLLBACK")
        expect(threw, "opening a locked store should fail, not start over")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        expect(!files.contains { $0.contains("broken") }, "\(files)")
        expect(try Store(directory: dir).item(id) != nil)
    },
    test("should keep a broken store's images with it when it is moved aside") {
        let dir = makeSandbox().appendingPathComponent("store")
        do { _ = try Store(directory: dir).ingest(imageCapture(bytes: 100_000, fill: 4), now: day(0)) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("mneme.sqlite").path, contents: Data(repeating: 7, count: 4096))
        try? FileManager.default.removeItem(atPath: dir.appendingPathComponent("mneme.sqlite-wal").path)
        let s = try Store(directory: dir)
        let moved = s.recoveredFrom!
        let keptBlobs = try FileManager.default.contentsOfDirectory(atPath: moved.path + "-Blobs")
        expectEqual(keptBlobs.count, 1)
        expectEqual(try s.applyRetention(maxAge: 30 * 86_400, now: day(1)).blobsRemoved, 0)
    },
    // I7
    test("should skip a copy when an excluded app was in front at any time since the last check") {
        var r = CaptureRules()
        r.recentBundleIDs = ["com.apple.keychainaccess", "com.apple.Safari"]
        let s = PasteboardSnapshot(changeCount: 1, types: [PasteType.plain], items: [[PasteType.plain: Data("pw".utf8)]])
        guard case .failure(let why) = classify(s, source: SourceApp(bundleID: "com.apple.Safari", name: "Safari"), rules: r) else { return expect(false) }
        expectEqual(why, .excludedApp)
    },
    // I8
    test("should fetch link previews only for public web addresses that are not one-time links") {
        for u in ["https://example.com/a", "https://www.apple.com/mac/?ref=x", "http://news.ycombinator.com/item?id=1"] {
            expect(shouldFetchPreview(URL(string: u)!), u)
        }
        for u in ["http://localhost:8000/api/run", "http://127.0.0.1/x", "http://192.168.1.5:8080", "http://10.0.0.2", "http://172.16.4.1",
                  "http://nas.local/", "http://router/", "http://[::1]:3000/", "https://app.example.com/login?token=abc123",
                  "https://example.com/verify?code=99", "https://example.com/reset-password/abc?sig=1", "ftp://example.com/a"] {
            expect(!shouldFetchPreview(URL(string: u)!), u)
        }
    },
    // I5
    test("should paste stacked items in order when ⌘V is pressed twice before the next one is ready") {
        var written: [String] = []
        let relay = StackRelay { written.append(String(data: $0.first!.data, encoding: .utf8)!) }
        func reps(_ s: String) -> [Representation] { [Representation(type: PasteType.plain, data: Data(s.utf8))] }
        relay.setUpcoming([reps("B"), reps("C")])   // A is on the clipboard
        relay.commandV()                      // paste 1 reads A
        relay.commandV()                      // paste 2 arrives before the scheduled switch: B must go on now
        expectEqual(written, ["B"])
        relay.flush()                         // the scheduled switch after paste 2 puts C on
        expectEqual(written, ["B", "C"])
        relay.flush()                         // nothing owed: nothing written
        expectEqual(written, ["B", "C"])
        relay.commandV(); relay.flush()       // paste 3 reads C; nothing left to put on
        expectEqual(written, ["B", "C"])
        expectEqual(relay.remaining, 0)
    },
    // I1
    test("should stop reading a copy once it is past the size cap") {
        let pb = scratch()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data(count: 3_000_000), forType: NSPasteboard.PasteboardType("public.rtf"))
        item.setData(Data(count: 3_000_000), forType: NSPasteboard.PasteboardType("public.html"))
        item.setData(Data("x".utf8), forType: .string)
        pb.writeObjects([item])
        var rules = CaptureRules(); rules.maxBytes = 2_000_000
        let s = snapshot(of: pb, rules: rules, source: finder)
        expect(s.items.flatMap(\.values).reduce(0) { $0 + $1.count } <= 3_000_001, "read too much")
        guard case .failure(let why) = classify(s, source: finder, rules: rules) else { return expect(false) }
        expectEqual(why, .tooLarge)
    },
    test("should read only one image format of a copy") {
        let pb = scratch()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data([1]), forType: NSPasteboard.PasteboardType("public.jpeg"))
        item.setData(Data([2]), forType: NSPasteboard.PasteboardType("public.tiff"))
        item.setData(Data([3]), forType: NSPasteboard.PasteboardType("public.heic"))
        pb.writeObjects([item])
        let s = snapshot(of: pb, rules: CaptureRules(), source: finder)
        expectEqual(s.items.first.map { Set($0.keys) }, ["public.jpeg"])
    },
]
