import AppKit
import ApplicationServices

/// Which image format to keep when an item offers several (the first one present).
private let imagePreference = [PasteType.png, "public.jpeg", "public.heic", PasteType.tiff, "com.compuserve.gif"]

/// What the pasteboard holds now. With `rules`, the types are checked first and the contents are not read at all
/// for a copy that will be skipped (a password manager's secret, an excluded app, Mneme's own write). Text types are
/// read first, one image format per item, and reading stops once the copy is past the size cap.
func snapshot(of pb: NSPasteboard, rules: CaptureRules? = nil, source: SourceApp? = nil) -> PasteboardSnapshot {
    let types = (pb.types ?? []).map(\.rawValue)
    var s = PasteboardSnapshot(changeCount: pb.changeCount, types: types, items: [])
    if let rules, case .failure(let why) = classify(s, source: source, rules: rules), why != .empty { return s }
    let cap = rules?.maxBytes ?? Int.max
    var total = 0
    for item in pb.pasteboardItems ?? [] {
        let itemTypes = item.types.map(\.rawValue)
        let image = imagePreference.first(where: itemTypes.contains)
        let wanted = itemTypes.filter { isKeptType($0) && (!PasteType.images.contains($0) || $0 == image) }
            .sorted { rank($0) < rank($1) }
        var data: [String: Data] = [:]
        for t in wanted {
            guard total <= cap else { break }
            if let d = item.data(forType: NSPasteboard.PasteboardType(t)) { data[t] = d; total += d.count }
        }
        s.items.append(data)
        if total > cap { break }
    }
    return s
}

/// Small, meaningful types first; images and unknown app types last.
private func rank(_ type: String) -> Int {
    switch type {
    case PasteType.plain, PasteType.url, PasteType.fileURL: return 0
    case PasteType.rtf, PasteType.html, PasteType.rtfd: return 1
    case _ where PasteType.images.contains(type): return 3
    default: return 2
    }
}

enum PasteResult { case pasted, copiedOnly }

/// Puts stored items back on the pasteboard and, when allowed, presses ⌘V in the app the user was in.
final class Paster {
    let store: Store
    let pasteboard: NSPasteboard

    init(store: Store, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
    }

    /// Writes the item (or only its plain text) marked as Mneme's own, and returns the new change count.
    @discardableResult
    func write(_ id: UUID, plainText: Bool) throws -> Int {
        Paster.write(try store.representations(id), plainText: plainText, fallbackText: try store.item(id)?.text, to: pasteboard)
    }

    /// Writes these representations (or only their plain text), marked as Mneme's own. Needs no store, so it can run
    /// anywhere once the bytes are loaded.
    @discardableResult
    static func write(_ reps: [Representation], plainText: Bool, fallbackText: String?, to pasteboard: NSPasteboard) -> Int {
        let own = NSPasteboard.PasteboardType(ownMarkerType)
        pasteboard.clearContents()
        if plainText {
            let text = reps.first { $0.type == PasteType.plain }.flatMap { String(data: $0.data, encoding: .utf8) } ?? fallbackText ?? ""
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data(), forType: own)
            pasteboard.writeObjects([item])
        } else {
            let grouped = Dictionary(grouping: reps, by: \.index).sorted { $0.key < $1.key }
            let items = grouped.map { _, reps -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for r in reps { item.setData(r.data, forType: NSPasteboard.PasteboardType(r.type)) }
                return item
            }
            items.first?.setData(Data(), forType: own)
            pasteboard.writeObjects(items)
        }
        return pasteboard.changeCount
    }

    /// Brings `app` back to the front and presses ⌘V there, if Accessibility is granted and auto-paste is on.
    /// Never asks for the permission. Call after `write`.
    @MainActor
    static func pressPaste(into app: NSRunningApplication?, autoPaste: Bool) async -> PasteResult {
        if let app {
            app.activate()
            for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        guard autoPaste, AXIsProcessTrusted() else { return .copiedOnly }
        // A private source: keys the user is still holding (⇧ after ⇧↩) do not leak into the ⌘V.
        let src = CGEventSource(stateID: .privateState)
        let vKey: CGKeyCode = 9
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        return .pasted
    }
}
