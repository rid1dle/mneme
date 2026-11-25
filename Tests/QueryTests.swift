import Foundation

private let mail = SourceApp(bundleID: "com.apple.mail", name: "Mail")
private func ids(_ s: Store, _ q: Query) throws -> [UUID] { try s.page(q, offset: 0, limit: 100).map(\.id) }
private func search(_ text: String) -> Query { var q = Query(); q.text = text; return q }

let queryTests: [TestCase] = [
    test("should find items by any word in their text, title, image text, link title or app name") {
        let s = try makeStore()
        let byText = try s.ingest(textCapture("quarterly invoice"), now: day(0))
        let byTitle = try s.ingest(textCapture("zzz"), now: day(1))
        try s.rename(byTitle.id, title: "Signature block", now: day(1))
        let byOCR = try s.ingest(imageCapture(bytes: 100, fill: 1), now: day(2))
        try s.setOCRText(byOCR.id, text: "Receipt total")
        let byLink = try s.ingest(textCapture("https://example.com/x"), now: day(3))
        try s.setLinkPreview(byLink.id, title: "Example Domain", image: nil)
        let byApp = try s.ingest(textCapture("hello there", source: mail), now: day(4))
        expectEqual(try ids(s, search("invoice")), [byText.id])
        expectEqual(try ids(s, search("signature")), [byTitle.id])
        expectEqual(try ids(s, search("receipt")), [byOCR.id])
        expectEqual(try ids(s, search("domain")), [byLink.id])
        expectEqual(try ids(s, search("mail")), [byApp.id])
    },
    test("should match a word being typed by its start") {
        let s = try makeStore()
        let a = try s.ingest(textCapture("the invoice is late"), now: day(0))
        expectEqual(try ids(s, search("invo")), [a.id])
        expectEqual(try ids(s, search("late invo")), [a.id])
        expectEqual(try ids(s, search("nothing")), [])
    },
    test("should treat search syntax as plain words") {
        expectEqual(ftsMatch("a\"b"), "\"a\"\"b\"*")
        expectEqual(ftsMatch("  "), nil)
        expectEqual(ftsMatch("*"), nil)
        let s = try makeStore()
        _ = try s.ingest(textCapture("near and or not"), now: day(0))
        for text in ["\"", "*", "-x", "(", "NEAR", "AND OR", "a:b", "^x", "{x}", "\"unterminated"] {
            do { _ = try s.page(search(text), offset: 0, limit: 10) } catch { expect(false, "\(text) threw \(error)") }
        }
        expectEqual(try ids(s, search("NEAR")).count, 1)
    },
    test("should show everything in History, newest first, when the search is empty") {
        let s = try makeStore()
        let a = try s.ingest(textCapture("one"), now: day(0))
        let b = try s.ingest(textCapture("two"), now: day(1))
        expectEqual(try ids(s, Query()), [b.id, a.id])
    },
    test("should filter by kind, source app and date, combined with text") {
        let s = try makeStore()
        let oldText = try s.ingest(textCapture("report draft"), now: day(0))
        let newText = try s.ingest(textCapture("report final", source: mail), now: day(10))
        let link = try s.ingest(textCapture("https://report.example.com"), now: day(10))
        var q = Query(); q.kinds = [.link]
        expectEqual(try ids(s, q), [link.id])
        q = Query(); q.sourceBundleID = mail.bundleID
        expectEqual(try ids(s, q), [newText.id])
        q = Query(); q.since = day(5)
        expectEqual(Set(try ids(s, q)), [newText.id, link.id])
        q = search("report"); q.kinds = [.text]
        expectEqual(try ids(s, q), [newText.id, oldText.id])
        q.since = day(5)
        expectEqual(try ids(s, q), [newText.id])
    },
    test("should show only a pinboard's items when one is selected, newest pin first") {
        let s = try makeStore()
        let board = try s.createPinboard(name: "Work", color: "#3A70C8", now: day(0))
        let a = try s.ingest(textCapture("a"), now: day(5))
        let b = try s.ingest(textCapture("b"), now: day(0))
        _ = try s.ingest(textCapture("c"), now: day(6))
        try s.pin(b.id, to: board.id, now: day(1))
        try s.pin(a.id, to: board.id, now: day(2))
        try s.removeFromHistory(b.id, now: day(3))
        var q = Query(); q.pinboard = board.id
        expectEqual(try ids(s, q), [a.id, b.id])
    },
    test("should keep a pinboard in the order the user dragged it into") {
        let s = try makeStore()
        let board = try s.createPinboard(name: "Work", color: "#3A70C8", now: day(0))
        let a = try s.ingest(textCapture("a"), now: day(0))
        let b = try s.ingest(textCapture("b"), now: day(0))
        let c = try s.ingest(textCapture("c"), now: day(0))
        for (n, x) in [a, b, c].enumerated() { try s.pin(x.id, to: board.id, now: day(Double(n))) }
        var q = Query(); q.pinboard = board.id
        expectEqual(try ids(s, q), [c.id, b.id, a.id])
        try s.movePinned(a.id, in: board.id, to: 0, now: day(5))
        expectEqual(try ids(s, q), [a.id, c.id, b.id])
        try s.movePinned(a.id, in: board.id, to: 2, now: day(6))
        expectEqual(try ids(s, q), [c.id, b.id, a.id])
        try s.movePinned(c.id, in: board.id, to: 99, now: day(7))
        expectEqual(try ids(s, q), [b.id, a.id, c.id])
        let d = try s.ingest(textCapture("d"), now: day(8))
        try s.pin(d.id, to: board.id, now: day(8))
        expectEqual(try ids(s, q).first, d.id)
    },
    test("should not load the full text when listing a page") {
        let s = try makeStore()
        _ = try s.ingest(textCapture("full text here"), now: day(0))
        let item = try s.page(Query(), offset: 0, limit: 1).first
        expectEqual(item?.text, nil)
        expectEqual(item?.preview, "full text here")
    },
    test("should page through 10,000 items without gaps or repeats") {
        let s = try makeStore()
        try bulkInsert(s, count: 10_000)
        var seen: [UUID] = []
        var offset = 0
        while true {
            let page = try s.page(Query(), offset: offset, limit: 60)
            if page.isEmpty { break }
            seen += page.map(\.id)
            offset += page.count
        }
        expectEqual(seen.count, 10_000)
        expectEqual(Set(seen).count, 10_000)
    },
    test("should return the first page of 10,000 items in under 20 ms") {
        let s = try makeStore()
        try bulkInsert(s, count: 10_000)
        _ = try s.page(Query(), offset: 0, limit: 60)
        let start = Date()
        _ = try s.page(Query(), offset: 0, limit: 60)
        _ = try s.page(search("item 99"), offset: 0, limit: 60)
        let ms = Date().timeIntervalSince(start) * 1000 / 2
        expect(ms < 20, "took \(ms) ms")
    },
    test("should list source apps most used first") {
        let s = try makeStore()
        _ = try s.ingest(textCapture("1", source: mail), now: day(0))
        _ = try s.ingest(textCapture("2", source: mail), now: day(0))
        _ = try s.ingest(textCapture("3"), now: day(0))
        expectEqual(try s.sourceApps(), [mail, finder])
    },
]
