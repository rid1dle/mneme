import AppKit
import Foundation

/// Made-up stores for screenshots and measurements: `build/tests --fixture <dir> normal|long|many|empty`.
enum ScreenFixture {
    static let apps = [
        SourceApp(bundleID: "com.apple.Safari", name: "Safari"), SourceApp(bundleID: "com.apple.mail", name: "Mail"),
        SourceApp(bundleID: "com.apple.Notes", name: "Notes"), SourceApp(bundleID: "com.microsoft.VSCode", name: "Code"),
        SourceApp(bundleID: "com.apple.finder", name: "Finder"), SourceApp(bundleID: "com.apple.Terminal", name: "Terminal"),
    ]

    static func build(at dir: URL, variant: String) throws {
        try? FileManager.default.removeItem(at: dir)
        let store = try Store(directory: dir)
        let now = Date()
        var t = now.addingTimeInterval(-14 * 3600)
        func next(_ minutes: Double) -> Date { t = t.addingTimeInterval(minutes * 60); return min(t, now) }
        func add(_ s: PasteboardSnapshot, _ app: SourceApp, _ minutes: Double) throws -> Item? {
            guard case .success(let c) = classify(s, source: app, rules: CaptureRules()) else { return nil }
            let item = try store.ingest(c, now: next(minutes))
            if c.kind == .image, let data = c.representations.first?.data, let th = makeThumbnail(data: data) {
                let name = "\(c.hash).png"
                try th.png.write(to: store.thumbs.appendingPathComponent(name))
                try store.setThumb(item.id, name: name, width: th.width, height: th.height)
            }
            return item
        }
        func text(_ s: String) -> PasteboardSnapshot { snap([PasteType.plain: Data(s.utf8)]) }
        func snap(_ d: [String: Data]) -> PasteboardSnapshot { PasteboardSnapshot(changeCount: 1, types: Array(d.keys), items: [d]) }

        switch variant {
        case "empty":
            return
        case "many":
            try store.db.transaction {
                for n in 0..<10_000 {
                    let id = UUID(), at = now.addingTimeInterval(-Double(10_000 - n) * 60)
                    let body = "Note \(n): " + sampleTexts[n % sampleTexts.count]
                    try store.db.run("""
                        INSERT INTO items(id, kind, text, preview, hash, byte_size, char_count, source_bundle, source_name, created_at, updated_at, last_used_at, search_id)
                        VALUES (?, 'text', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \(n + 1))
                        """, [id, body, String(body.prefix(previewLength)), "many-\(n)", body.utf8.count, body.count,
                              apps[n % apps.count].bundleID, apps[n % apps.count].name, at, at, at])
                    try store.db.run("INSERT INTO representations(item_id, ord, item_index, type, inline, size) VALUES (?, 0, 0, ?, ?, ?)",
                                     [id, PasteType.plain, Data(body.utf8), body.utf8.count])
                    try store.refreshSearch(id)
                }
            }
            return
        case "long":
            _ = try add(text(String(repeating: "A very long paragraph that keeps going without a break so the card has to cut it off cleanly. ", count: 40)), apps[2], 10)
            _ = try add(text("https://example.com/" + String(repeating: "deeply/nested/path/", count: 12) + "?utm_source=newsletter&utm_campaign=very-long-campaign-name"), apps[0], 10)
            let files = (0..<6).map { dir.appendingPathComponent("Quarterly report draft version \($0) with a really long file name.pdf") }
            for f in files { FileManager.default.createFile(atPath: f.path, contents: Data("x".utf8)) }
            _ = try add(PasteboardSnapshot(changeCount: 1, types: [PasteType.fileURL], items: files.map { [PasteType.fileURL: Data($0.absoluteString.utf8)] }), apps[4], 10)
            let i = try add(text("short"), apps[3], 10)
            try store.rename(i!.id, title: "A title that is far too long to fit on one card header line", now: next(1))
            return
        default:
            break
        }

        let work = try store.createPinboard(name: "Work", color: "#0A84FF", now: now)
        let snippets = try store.createPinboard(name: "Snippets", color: "#30D158", now: now)
        _ = try store.createPinboard(name: "Design", color: "#FF9F0A", now: now)
        let docs = dir.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let invoice = docs.appendingPathComponent("Invoice 2026-11.pdf")
        FileManager.default.createFile(atPath: invoice.path, contents: Data("pdf".utf8))
        let sheet = docs.appendingPathComponent("Budget.numbers")
        FileManager.default.createFile(atPath: sheet.path, contents: Data("n".utf8))
        let gone = docs.appendingPathComponent("Old contract.docx")

        for n in 0..<4 {
            for (k, body) in sampleTexts.enumerated() where (k + n) % 3 == 0 {
                _ = try add(text(body), apps[(k + n) % apps.count], 37)
            }
            _ = try add(text("https://www.apple.com/macbook-air/"), apps[0], 21)
            _ = try add(text(["#0A84FF", "rgb(255, 159, 10)", "#30D158", "hsl(280, 70%, 60%)"][n]), apps[3], 13)
            _ = try add(snap([PasteType.png: image(hue: Double(n) / 4, width: 1600, height: 1000)]), apps[4], 29)
            let rich = NSAttributedString(string: "Meeting notes \(n + 1): agree the launch date and owners", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            _ = try add(snap([PasteType.rtf: rich.rtf(from: NSRange(location: 0, length: rich.length))!, PasteType.plain: Data(rich.string.utf8)]), apps[1], 19)
        }
        _ = try add(PasteboardSnapshot(changeCount: 1, types: [PasteType.fileURL], items: [[PasteType.fileURL: Data(invoice.absoluteString.utf8)], [PasteType.fileURL: Data(sheet.absoluteString.utf8)]]), apps[4], 5)
        _ = try add(PasteboardSnapshot(changeCount: 1, types: [PasteType.fileURL], items: [[PasteType.fileURL: Data(gone.absoluteString.utf8)]]), apps[4], 5)
        if let link = try add(text("https://developer.apple.com/documentation/vision"), apps[0], 4),
           let t = makeThumbnail(data: image(hue: 0.58, width: 1200, height: 630)) {
            let name = "link-\(link.id.uuidString).png"
            try t.png.write(to: store.blobs.appendingPathComponent(name))
            try store.setLinkPreview(link.id, title: "Vision | Apple Developer Documentation", image: name)
        }
        let sig = try add(text("Best regards,\nRid\nVishwa Labs"), apps[1], 3)
        try store.rename(sig!.id, title: "Email signature", now: next(1))
        try store.pin(sig!.id, to: snippets.id, now: next(1))
        let inv = try add(text("Invoice INV-2026-0042 is due on 30 November. Amount: 1,24,500 INR."), apps[1], 2)
        try store.pin(inv!.id, to: work.id, now: next(1))
        _ = try add(text("SELECT id, name FROM items WHERE deleted_at IS NULL ORDER BY last_used_at DESC LIMIT 60;"), apps[3], 1)
    }

    static let sampleTexts = [
        "Can we move the review to Thursday at 4? Wednesday is packed.",
        "brew install --cask visual-studio-code",
        "The quarterly invoice needs the new tax line before it goes out.",
        "let first = items.first { $0.kind == .image }",
        "Flight AI 504, seat 14C, boarding 06:35 from gate 22.",
        "Remember to renew the domain before 12 December.",
        "git log --oneline --since=\"2 weeks ago\" | wc -l",
        "Thanks for the quick turnaround, this looks great.",
        "Shipping address: 221B Baker Street, London NW1 6XE",
        "ssh -L 5432:localhost:5432 bastion.internal",
    ]

    static func image(hue: Double, width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(starting: NSColor(hue: hue, saturation: 0.65, brightness: 0.95, alpha: 1),
                   ending: NSColor(hue: hue + 0.15, saturation: 0.8, brightness: 0.55, alpha: 1))!.draw(in: rect, angle: -35)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: width / 6, y: height / 4, width: height / 2, height: height / 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
