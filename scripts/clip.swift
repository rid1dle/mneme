// Test helper for live checks: saves, restores and fills the general pasteboard.
//   clip save <file> | clip restore <file> | clip text <s> | clip rtf | clip png | clip files <path>... | clip secret <s>
import AppKit

let pb = NSPasteboard.general
let args = Array(CommandLine.arguments.dropFirst())
func put(_ items: [NSPasteboardItem]) { pb.clearContents(); pb.writeObjects(items) }
func item(_ pairs: [(String, Data)]) -> NSPasteboardItem {
    let i = NSPasteboardItem()
    for (t, d) in pairs { i.setData(d, forType: NSPasteboard.PasteboardType(t)) }
    return i
}

switch args.first {
case "save":
    let saved = (pb.pasteboardItems ?? []).map { i in
        Dictionary(uniqueKeysWithValues: i.types.compactMap { t in i.data(forType: t).map { (t.rawValue, $0) } })
    }
    let data = try! PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
    try! data.write(to: URL(fileURLWithPath: args[1]))
    print("saved \(saved.count) items")
case "restore":
    let data = try! Data(contentsOf: URL(fileURLWithPath: args[1]))
    let saved = try! PropertyListSerialization.propertyList(from: data, format: nil) as! [[String: Data]]
    put(saved.map { item($0.map { ($0.key, $0.value) }) })
    print("restored \(saved.count) items")
case "text": put([item([("public.utf8-plain-text", Data(args[1].utf8))])])
case "rtf":
    let s = NSAttributedString(string: "Bold quarterly note", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
    let rtf = s.rtf(from: NSRange(location: 0, length: s.length), documentAttributes: [:])!
    put([item([("public.rtf", rtf), ("public.utf8-plain-text", Data(s.string.utf8))])])
case "png":
    let img = NSImage(size: NSSize(width: 1600, height: 900), flipped: false) { r in
        NSColor.systemTeal.setFill(); r.fill(); return true
    }
    let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    put([item([("public.png", png)])])
case "textimage":
    let img = NSImage(size: NSSize(width: 1200, height: 300), flipped: false) { r in
        NSColor.white.setFill(); r.fill()
        (args[1] as NSString).draw(at: NSPoint(x: 40, y: 120), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        return true
    }
    let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    put([item([("public.png", png)])])
case "fileimage":
    let img = NSImage(size: NSSize(width: 900, height: 240), flipped: false) { r in
        NSColor.white.setFill(); r.fill()
        (args[1] as NSString).draw(at: NSPoint(x: 30, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        return true
    }
    let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CleanShot test.png")
    try! png.write(to: url)
    put([item([("public.file-url", Data(url.absoluteString.utf8)), ("public.png", png)])])
case "huge":
    put([item([("public.rtf", Data(count: 60_000_000)), ("public.utf8-plain-text", Data("huge".utf8))])])
case "files": put(args.dropFirst().map { item([("public.file-url", Data(URL(fileURLWithPath: $0).absoluteString.utf8))]) })
case "secret": put([item([("public.utf8-plain-text", Data(args[1].utf8)), ("org.nspasteboard.ConcealedType", Data())])])
default: print("usage: clip save|restore|text|rtf|png|files|secret")
}
