import AppKit
import Foundation

private func scratchPasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("mneme-tests-\(UUID().uuidString)")) }

private func pngData(width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

private func richCapture() -> Capture {
    let s = PasteboardSnapshot(changeCount: 1, types: [PasteType.rtf, PasteType.plain], items: [[
        PasteType.rtf: Data("{\\rtf1 {\\b bold}}".utf8), PasteType.plain: Data("bold".utf8)]])
    guard case .success(let c) = classify(s, source: finder, rules: CaptureRules()) else { fatalError() }
    return c
}

let appBridgeTests: [TestCase] = [
    test("should write an item back to a pasteboard exactly as it was captured") {
        let store = try makeStore()
        let item = try store.ingest(richCapture(), now: day(0))
        let pb = scratchPasteboard()
        let count = try Paster(store: store, pasteboard: pb).write(item.id, plainText: false)
        expectEqual(count, pb.changeCount)
        expectEqual(pb.data(forType: NSPasteboard.PasteboardType(PasteType.rtf)), Data("{\\rtf1 {\\b bold}}".utf8))
        expectEqual(pb.string(forType: .string), "bold")
        expect(pb.types?.contains(NSPasteboard.PasteboardType(ownMarkerType)) == true)
    },
    test("should write only plain text when pasting as plain text") {
        let store = try makeStore()
        let item = try store.ingest(richCapture(), now: day(0))
        let pb = scratchPasteboard()
        _ = try Paster(store: store, pasteboard: pb).write(item.id, plainText: true)
        expectEqual(pb.string(forType: .string), "bold")
        expectEqual(pb.data(forType: NSPasteboard.PasteboardType(PasteType.rtf)), nil)
    },
    test("should write several files as several pasteboard items") {
        let store = try makeStore()
        let s = PasteboardSnapshot(changeCount: 1, types: [PasteType.fileURL], items: [
            [PasteType.fileURL: Data("file:///tmp/a.txt".utf8)], [PasteType.fileURL: Data("file:///tmp/b.txt".utf8)]])
        guard case .success(let c) = classify(s, source: finder, rules: CaptureRules()) else { return expect(false) }
        let item = try store.ingest(c, now: day(0))
        let pb = scratchPasteboard()
        _ = try Paster(store: store, pasteboard: pb).write(item.id, plainText: false)
        expectEqual(pb.pasteboardItems?.count, 2)
        expectEqual(pb.readObjects(forClasses: [NSURL.self])?.compactMap { ($0 as? URL)?.path }, ["/tmp/a.txt", "/tmp/b.txt"])
    },
    test("should recognise its own write when the watcher sees it next") {
        let store = try makeStore()
        let item = try store.ingest(richCapture(), now: day(0))
        let pb = scratchPasteboard()
        _ = try Paster(store: store, pasteboard: pb).write(item.id, plainText: false)
        guard case .failure(let why) = classify(snapshot(of: pb), source: finder, rules: CaptureRules()) else { return expect(false) }
        expectEqual(why, .ownWrite)
    },
    test("should read every pasteboard item and skip the tiff copy of a png") {
        let pb = scratchPasteboard()
        pb.clearContents()
        let a = NSPasteboardItem(), b = NSPasteboardItem()
        a.setData(Data([1]), forType: NSPasteboard.PasteboardType(PasteType.png))
        a.setData(Data([2]), forType: NSPasteboard.PasteboardType(PasteType.tiff))
        b.setString("second", forType: .string)
        pb.writeObjects([a, b])
        let s = snapshot(of: pb)
        expectEqual(s.items.count, 2)
        expectEqual(s.items[0][PasteType.tiff], nil)
        expectEqual(s.items[0][PasteType.png], Data([1]))
        expectEqual(s.items[1][PasteType.plain], Data("second".utf8))
        expectEqual(s.changeCount, pb.changeCount)
    },
    test("should not read the contents of a copy it is going to skip") {
        let pb = scratchPasteboard()
        pb.clearContents()
        pb.setString("hunter2", forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType(PasteType.concealed))
        let s = snapshot(of: pb, rules: CaptureRules(), source: finder)
        expectEqual(s.items.flatMap { $0.keys }.count, 0)
        guard case .failure(let why) = classify(s, source: finder, rules: CaptureRules()) else { return expect(false) }
        expectEqual(why, .concealed)
    },
    test("should make a thumbnail no larger than 400 pixels and keep the real size") {
        let t = makeThumbnail(data: pngData(width: 2000, height: 1000))
        expectEqual(t?.width, 2000)
        expectEqual(t?.height, 1000)
        let thumb = t.flatMap { NSBitmapImageRep(data: $0.png) }
        expectEqual(thumb?.pixelsWide, 400)
        expectEqual(thumb?.pixelsHigh, 200)
    },
    test("should not crash on data that is not an image") {
        expect(makeThumbnail(data: Data([1, 2, 3])) == nil)
    },
    test("should build capture rules from settings") {
        let name = "mneme-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        expectEqual(captureRules(d, paused: false, ownChangeCount: nil).excludedBundleIDs, CaptureRules.defaultExcluded)
        expectEqual(captureRules(d, paused: false, ownChangeCount: nil).kinds, Set(ItemKind.allCases))
        d.set(["text", "link"], forKey: Pref.kinds)
        d.set(["com.example.secret"], forKey: Pref.excluded)
        let r = captureRules(d, paused: true, ownChangeCount: 4)
        expectEqual(r.kinds, [.text, .link])
        expectEqual(r.excludedBundleIDs, ["com.example.secret"])
        expect(r.paused)
        expectEqual(r.ownChangeCount, 4)
        expectEqual(historyMaxAge(d), 30 * 86_400)
        d.set(0, forKey: Pref.historyDays)
        expectEqual(historyMaxAge(d), nil)
    },
]

let shelfWindowTests: [TestCase] = [
    test("should draw the shelf's own rounded shadow instead of the system's square one") {
        let p = ShelfPanel()
        expect(!p.hasShadow, "the system shadow came out square around the rounded shelf")
        expect(!p.isOpaque && p.backgroundColor == .clear, "the margin around the shelf must stay see-through")
        expect(ShelfPanel.margin >= 16, "the shadow and the open slide need room inside the window")
    },
    test("should let the real shelf take keys after an off-screen drawing") {
        let p = ShelfPanel()
        p.prepare(offscreen: true)
        expect(!p.canBecomeKey, "an off-screen drawing must not take focus")
        p.prepare(offscreen: false)
        expect(p.canBecomeKey, "the real shelf must take focus so Esc and typing reach it")
    },
]
