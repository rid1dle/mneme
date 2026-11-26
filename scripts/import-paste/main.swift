// Imports Paste's history (a copy of its Core Data db.sqlite) into a Mneme store through Mneme's own capture rules.
//   swiftc -O -o build/import_paste Sources/Core/*.swift Sources/App/{Thumbs,Prefs}.swift scripts/import-paste/main.swift
//   build/import_paste <db.sqlite copy> <Paste _EXTERNAL_DATA folder> <Mneme store folder> [--dry-run]
// Paste keeps each item as raw-deflate JSON: [{"types": [...], "dataByType": {type: base64}}], inline (prefix 0x01)
// or in an external file (prefix 0x02 + file name). Times are seconds since 2001.
import AppKit

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: import_paste <db.sqlite> <external dir> <store dir> [--dry-run]"); exit(2) }
let dry = args.contains("--dry-run")
let src = try Database(path: args[1])
let external = URL(fileURLWithPath: args[2])
let store = dry ? nil : try Store(directory: URL(fileURLWithPath: args[3]))

struct PastedItem: Decodable { let types: [String]; let dataByType: [String: String] }

func decode(_ blob: Data) -> [PastedItem]? {
    guard let marker = blob.first else { return nil }
    var packed = blob.dropFirst()
    if marker == 2 {
        let name = String(decoding: packed.prefix { $0 != 0 }, as: UTF8.self)
        guard let file = try? Data(contentsOf: external.appendingPathComponent(name)) else { return nil }
        packed = file[...]
    }
    guard let json = try? (Data(packed) as NSData).decompressed(using: .zlib) as Data else { return nil }
    return try? JSONDecoder().decode([PastedItem].self, from: json)
}

var apps: [Int: SourceApp] = [:]
try src.query("SELECT Z_PK, ZBUNDLEIDENTIFIER, ZNAME FROM ZAPPLICATIONENTITY") { r in
    if let id = r.text(1) { apps[r.int(0)] = SourceApp(bundleID: id, name: r.text(2) ?? id) }
}

var rules = captureRules(UserDefaults(suiteName: "local.mneme") ?? .standard, paused: false, ownChangeCount: nil)
rules.ownChangeCount = nil
var counts: [String: Int] = [:]
var rows: [(source: Int?, at: Double, title: String?, blob: Data)] = []
try src.query("""
    SELECT i.ZSOURCEAPPLICATION, COALESCE(i.ZTIMESTAMP, i.ZCREATEDAT), i.ZTITLE, d.ZRAWPASTEBOARDITEMS
    FROM ZITEMENTITY i JOIN ZITEMDATAENTITY d ON d.ZITEM = i.Z_PK ORDER BY 2
    """) { r in
    rows.append((r.isNull(0) ? nil : r.int(0), r.double(1), r.text(2), r.blob(3) ?? Data()))
}
for row in rows {
    guard let pasted = decode(row.blob) else { counts["unreadable", default: 0] += 1; continue }
    let items = pasted.map { p in p.dataByType.compactMapValues { Data(base64Encoded: $0) } }
    let snap = PasteboardSnapshot(changeCount: -1, types: Array(Set(pasted.flatMap(\.types))), items: items)
    let source = row.source.flatMap { apps[$0] }
    switch classify(snap, source: source, rules: rules) {
    case .failure(let why):
        counts["skipped: \(why)", default: 0] += 1
    case .success(let capture):
        counts[capture.kind.rawValue, default: 0] += 1
        guard let store else { continue }
        let at = Date(timeIntervalSinceReferenceDate: row.at)
        var item = try store.ingest(capture, now: at)
        if let title = row.title, !title.isEmpty { try store.rename(item.id, title: title, now: at) }
        if item.kind == .image, item.thumb == nil {
            item = storeThumbnail(store, item, imageData: capture.representations.first { PasteType.images.contains($0.type) }?.data)
        }
    }
}
print((dry ? "dry run, would import: " : "imported: ") + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
