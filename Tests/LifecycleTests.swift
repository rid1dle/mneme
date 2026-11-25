import Foundation

let lifecycleTests: [TestCase] = [
    test("should add a new copy to the front of History") {
        let s = try makeStore()
        let a = try s.ingest(textCapture("first"), now: day(0))
        let b = try s.ingest(textCapture("second"), now: day(1))
        expect(a.inHistory && b.inHistory)
        expectEqual(try s.historyIDs(), [b.id, a.id])
        expectEqual(try s.item(a.id)?.text, "first")
        expectEqual(try s.item(a.id)?.source, finder)
    },
    test("should move a repeated copy to the front instead of adding a second item") {
        let s = try makeStore()
        let a = try s.ingest(textCapture("same"), now: day(0))
        _ = try s.ingest(textCapture("other"), now: day(1))
        let again = try s.ingest(textCapture("same"), now: day(2))
        expectEqual(again.id, a.id)
        expectEqual(try s.historyIDs().first, a.id)
        expectEqual(try s.historyIDs().count, 2)
        expectEqual(try s.item(a.id)?.lastUsedAt, day(2))
        expectEqual(try s.item(a.id)?.createdAt, day(0))
    },
    test("should put a copy back in History without touching its pinboards") {
        let s = try makeStore()
        let board = try s.createPinboard(name: "Work", color: "#3A70C8", now: day(0))
        let a = try s.ingest(textCapture("pinned"), now: day(0))
        try s.pin(a.id, to: board.id, now: day(0))
        try s.removeFromHistory(a.id, now: day(1))
        expectEqual(try s.item(a.id)?.inHistory, false)
        _ = try s.ingest(textCapture("pinned"), now: day(2))
        expectEqual(try s.item(a.id)?.inHistory, true)
        expectEqual(try s.pinboards(of: a.id), [board.id])
    },
    test("should keep a pinned item on its pinboard when it is deleted from History") {
        let s = try makeStore()
        let board = try s.createPinboard(name: "Work", color: "#3A70C8", now: day(0))
        let a = try s.ingest(textCapture("keep me"), now: day(0))
        try s.pin(a.id, to: board.id, now: day(0))
        try s.removeFromHistory(a.id, now: day(1))
        expect(try s.item(a.id) != nil)
        expectEqual(try s.historyIDs(), [])
        expectEqual(try s.pinboards(of: a.id), [board.id])
    },
    test("should delete an item that is in neither History nor any pinboard") {
        let s = try makeStore()
        let board = try s.createPinboard(name: "Work", color: "#3A70C8", now: day(0))
        let a = try s.ingest(textCapture("gone"), now: day(0))
        try s.removeFromHistory(a.id, now: day(1))
        expect(try s.item(a.id) == nil)
        let b = try s.ingest(textCapture("unpinned later"), now: day(0))
        try s.pin(b.id, to: board.id, now: day(0))
        try s.removeFromHistory(b.id, now: day(1))
        try s.unpin(b.id, from: board.id, now: day(2))
        expect(try s.item(b.id) == nil)
        expectEqual(try ftsBody(s, b.id), nil)
    },
    test("should remove an item from History and every pinboard when deleted everywhere") {
        let s = try makeStore()
        let one = try s.createPinboard(name: "One", color: "#111111", now: day(0))
        let two = try s.createPinboard(name: "Two", color: "#222222", now: day(0))
        let a = try s.ingest(textCapture("everywhere"), now: day(0))
        try s.pin(a.id, to: one.id, now: day(0))
        try s.pin(a.id, to: two.id, now: day(0))
        try s.deleteEverywhere(a.id, now: day(1))
        expect(try s.item(a.id) == nil)
        expectEqual(try s.pinboards(of: a.id), [])
        expectEqual(try s.historyIDs(), [])
    },
    test("should keep the same id when text is edited or renamed") {
        let s = try makeStore()
        let a = try s.ingest(textCapture("draft"), now: day(0))
        try s.editText(a.id, text: "final wording", now: day(1))
        try s.rename(a.id, title: "Signature", now: day(1))
        let e = try s.item(a.id)
        expectEqual(e?.text, "final wording")
        expectEqual(e?.title, "Signature")
        expectEqual(e?.updatedAt, day(1))
        expectEqual(try s.representations(a.id), [Representation(type: PasteType.plain, data: Data("final wording".utf8))])
        let body = try ftsBody(s, a.id) ?? ""
        expect(body.contains("final wording") && body.contains("Signature") && !body.contains("draft"), body)
    },
    test("should keep the formatting when rich text is edited") {
        let s = try makeStore()
        let rich = PasteboardSnapshot(changeCount: 1, types: [PasteType.rtf, PasteType.plain, PasteType.html], items: [[
            PasteType.rtf: Data("{\\rtf1 {\\b old}}".utf8), PasteType.plain: Data("old".utf8), PasteType.html: Data("<b>old</b>".utf8)]])
        guard case .success(let c) = classify(rich, source: finder, rules: CaptureRules()) else { return expect(false) }
        let a = try s.ingest(c, now: day(0))
        let newRTF = Data("{\\rtf1 {\\b new}}".utf8)
        try s.editText(a.id, text: "new", rtf: newRTF, now: day(1))
        expectEqual(try s.item(a.id)?.kind, .richText)
        expectEqual(try s.item(a.id)?.text, "new")
        let reps = try s.representations(a.id)
        expectEqual(Set(reps.map(\.type)), [PasteType.plain, PasteType.rtf])
        expectEqual(reps.first { $0.type == PasteType.rtf }?.data, newRTF)
    },
    test("should replace an image in place when it is edited in Preview") {
        let s = try makeStore()
        let board = try s.createPinboard(name: "Shots", color: "#3A70C8", now: day(0))
        let a = try s.ingest(imageCapture(bytes: 120_000, fill: 1), now: day(0))
        try s.setThumb(a.id, name: "old.png", width: 10, height: 10)
        try s.pin(a.id, to: board.id, now: day(0))
        let edited = Data(repeating: 2, count: 90_000)
        try s.replaceImage(a.id, png: edited, now: day(1))
        let e = try s.item(a.id)
        expectEqual(try s.representations(a.id), [Representation(type: PasteType.png, data: edited)])
        expect(e?.hash != a.hash)
        expectEqual(e?.thumb, nil)
        expectEqual(e?.byteSize, 90_000)
        expectEqual(e?.updatedAt, day(1))
        expectEqual(try s.pinboards(of: a.id), [board.id])
        expectEqual(try s.pendingOCR(limit: 5).map(\.id), [a.id])
    },
    test("should stop pointing at the original file once a copied image file is edited") {
        let s = try makeStore()
        let snap = PasteboardSnapshot(changeCount: 1, types: [PasteType.fileURL, PasteType.png], items: [[
            PasteType.fileURL: Data("file:///tmp/shot.png".utf8), PasteType.png: Data(repeating: 1, count: 50)]])
        guard case .success(let c) = classify(snap, source: finder, rules: CaptureRules()) else { return expect(false) }
        let a = try s.ingest(c, now: day(0))
        expectEqual(try s.item(a.id)?.fileURLs.count, 1)
        try s.replaceImage(a.id, png: Data(repeating: 2, count: 60), now: day(1))
        expectEqual(try s.item(a.id)?.fileURLs, [])
        expectEqual(try s.item(a.id)?.kind, .image)
    },
    test("should drop History entries older than the chosen age but keep them on pinboards") {
        let s = try makeStore()
        let board = try s.createPinboard(name: "Keep", color: "#3A70C8", now: day(0))
        let old = try s.ingest(textCapture("old"), now: day(0))
        let oldPinned = try s.ingest(textCapture("old pinned"), now: day(0))
        let fresh = try s.ingest(textCapture("fresh"), now: day(39))
        try s.pin(oldPinned.id, to: board.id, now: day(0))
        let report = try s.applyRetention(maxAge: 30 * 86_400, now: day(40))
        expectEqual(report, RetentionReport(leftHistory: 2, deleted: 1, blobsRemoved: 0, tombstonesPurged: 0))
        expect(try s.item(old.id) == nil)
        expectEqual(try s.item(oldPinned.id)?.inHistory, false)
        expectEqual(try s.pinboards(of: oldPinned.id), [board.id])
        expectEqual(try s.historyIDs(), [fresh.id])
    },
    test("should keep everything when history is kept forever") {
        let s = try makeStore()
        _ = try s.ingest(textCapture("ancient"), now: day(0))
        expectEqual(try s.applyRetention(maxAge: nil, now: day(4000)), RetentionReport(leftHistory: 0, deleted: 0, blobsRemoved: 0, tombstonesPurged: 0))
        expectEqual(try s.historyIDs().count, 1)
    },
    test("should remove blob files no remaining item uses") {
        let s = try makeStore()
        let big = try s.ingest(imageCapture(bytes: 100_000, fill: 1), now: day(0))
        _ = try s.ingest(imageCapture(bytes: 100_000, fill: 2), now: day(39))
        expectEqual(blobFiles(s).count, 2)
        let report = try s.applyRetention(maxAge: 30 * 86_400, now: day(40))
        expectEqual(report.blobsRemoved, 1)
        expectEqual(blobFiles(s).count, 1)
        expect(try s.item(big.id) == nil)
    },
    test("should purge deletion markers older than 30 days") {
        let s = try makeStore()
        let a = try s.ingest(textCapture("bye"), now: day(0))
        try s.deleteEverywhere(a.id, now: day(1))
        expectEqual(try s.applyRetention(maxAge: nil, now: day(20)).tombstonesPurged, 0)
        expectEqual(try s.applyRetention(maxAge: nil, now: day(32)).tombstonesPurged, 1)
        expectEqual(try s.db.scalarInt("SELECT COUNT(*) FROM items"), 0)
    },
    test("should clear History but leave pinboards untouched") {
        let s = try makeStore()
        let board = try s.createPinboard(name: "Keep", color: "#3A70C8", now: day(0))
        let a = try s.ingest(textCapture("a"), now: day(0))
        let b = try s.ingest(textCapture("b"), now: day(0))
        try s.pin(b.id, to: board.id, now: day(0))
        try s.clearHistory(now: day(1))
        expectEqual(try s.historyIDs(), [])
        expect(try s.item(a.id) == nil)
        expect(try s.item(b.id) != nil)
        expectEqual(try s.pinboards(of: b.id), [board.id])
    },
    test("should store a large representation as a file and read it back unchanged") {
        let s = try makeStore()
        let c = imageCapture(bytes: 100_000, fill: 9)
        let a = try s.ingest(c, now: day(0))
        expectEqual(blobFiles(s).count, 1)
        expectEqual(try s.representations(a.id), c.representations)
    },
    test("should keep a small representation inside the database") {
        let s = try makeStore()
        let a = try s.ingest(textCapture("tiny"), now: day(0))
        expectEqual(blobFiles(s).count, 0)
        expectEqual(try s.representations(a.id).first?.data, Data("tiny".utf8))
    },
    test("should store only the start of a huge text for search and keep the whole text for pasting") {
        let s = try makeStore()
        let huge = String(repeating: "x", count: 300_000)
        let a = try s.ingest(textCapture(huge), now: day(0))
        expectEqual(try s.item(a.id)?.text?.count, 100_000)
        expectEqual(try s.representations(a.id).first?.data.count, 300_000)
    },
    test("should order and manage pinboards") {
        let s = try makeStore()
        let a = try s.createPinboard(name: "A", color: "#111111", now: day(0))
        let b = try s.createPinboard(name: "B", color: "#222222", now: day(0))
        let c = try s.createPinboard(name: "C", color: "#333333", now: day(0))
        try s.movePinboard(c.id, to: 0)
        expectEqual(try s.allPinboards().map(\.name), ["C", "A", "B"])
        try s.renamePinboard(a.id, name: "Alpha", now: day(1))
        try s.recolorPinboard(a.id, color: "#AAAAAA", now: day(1))
        let item = try s.ingest(textCapture("only on B"), now: day(0))
        try s.pin(item.id, to: b.id, now: day(0))
        try s.removeFromHistory(item.id, now: day(0))
        try s.deletePinboard(b.id, now: day(2))
        expectEqual(try s.allPinboards().map(\.name), ["C", "Alpha"])
        expectEqual(try s.allPinboards().last?.color, "#AAAAAA")
        expect(try s.item(item.id) == nil)
    },
    test("should let a new copy of deleted content start a fresh item") {
        let s = try makeStore()
        let a = try s.ingest(textCapture("again"), now: day(0))
        try s.deleteEverywhere(a.id, now: day(1))
        let b = try s.ingest(textCapture("again"), now: day(2))
        expect(b.id != a.id)
        expectEqual(try s.historyIDs(), [b.id])
    },
    test("should record text read from an image and list images still to read") {
        let s = try makeStore()
        let img = try s.ingest(imageCapture(bytes: 500, fill: 3), now: day(0))
        _ = try s.ingest(textCapture("not an image"), now: day(0))
        expectEqual(try s.pendingOCR(limit: 10).map(\.id), [img.id])
        try s.setOCRText(img.id, text: "Invoice 42")
        expectEqual(try s.pendingOCR(limit: 10).count, 0)
        expect((try ftsBody(s, img.id) ?? "").contains("Invoice 42"))
    },
]

let charCountTests: [TestCase] = [
    test("should count the characters of a copied text once, when it is stored") {
        let s = try makeStore()
        let a = try s.ingest(textCapture("héllo 👋"), now: day(0))
        expectEqual(try s.item(a.id)?.charCount, 7)
        expectEqual(try s.page(Query(), offset: 0, limit: 1).first?.charCount, 7)
        try s.editText(a.id, text: "hi", now: day(1))
        expectEqual(try s.item(a.id)?.charCount, 2)
    },
]
