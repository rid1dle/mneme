import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The full content of one item, loaded only for the preview.
struct FullItem {
    var text: String?
    var attributed: NSAttributedString?
    var image: NSImage?
}

extension ShelfModel {
    private func write(_ body: @escaping @Sendable (Store) throws -> Void) {
        storeQueue.async { [store] in
            try? body(store)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.reload(keepSelection: true) } }
        }
    }

    /// Delete in History removes it from History (it stays on its pinboards); in a pinboard it unpins it.
    func removeFromCurrent(_ item: Item) {
        let id = item.id, board = pinboard
        write { store in
            if let board { try store.unpin(id, from: board, now: Date()) } else { try store.removeFromHistory(id, now: Date()) }
        }
    }

    /// Asks first when the item is on a pinboard (it would be lost there too).
    func deleteEverywhere(_ item: Item, confirmed: Bool = false) {
        let id = item.id
        guard !confirmed else {
            overlay = nil
            write { try $0.deleteEverywhere(id, now: Date()) }
            return
        }
        storeQueue.async { [store] in
            let boards = (try? store.pinboards(of: id).count) ?? 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if boards > 0 { self.overlay = .confirmDelete(item, pinboards: boards) } else { self.deleteEverywhere(item, confirmed: true) }
                }
            }
        }
    }

    func pin(_ item: Item, to board: UUID) {
        let id = item.id
        write { try $0.pin(id, to: board, now: Date()) }
    }

    func rename(_ item: Item, to title: String) {
        let id = item.id
        overlay = nil
        write { try $0.rename(id, title: title, now: Date()) }
    }

    static let pinboardColors = ["#0A84FF", "#30D158", "#FF9F0A", "#FF375F", "#BF5AF2", "#64D2FF", "#FFD60A", "#8E8E93"]

    func newPinboard(name: String, color: String, pinning item: Item?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        overlay = nil
        guard !trimmed.isEmpty else { return }
        let id = item?.id
        write { store in
            let board = try store.createPinboard(name: trimmed, color: color, now: Date())
            if let id { try store.pin(id, to: board.id, now: Date()) }
        }
    }

    /// Saves an edited text. Rich text keeps its formatting.
    func saveText(_ item: Item, _ text: NSAttributedString) {
        let id = item.id
        let rich = item.kind == .richText
        let rtf = rich ? text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:]) : nil
        let plain = text.string
        editing = false
        storeQueue.async { [store] in
            try? store.editText(id, text: plain, rtf: rtf, now: Date())
            let updated = try? store.item(id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let updated, case .preview = self.overlay { self.overlay = .preview(updated) }
                    self.reload(keepSelection: true)
                }
            }
        }
    }

    func loadFull(_ item: Item) async -> FullItem {
        let id = item.id
        let reps: [Representation] = await withCheckedContinuation { cont in
            storeQueue.async { [store] in cont.resume(returning: (try? store.representations(id)) ?? []) }
        }
        func data(_ type: String) -> Data? { reps.first { $0.type == type }?.data }
        var full = FullItem()
        full.text = data(PasteType.plain).flatMap { String(data: $0, encoding: .utf8) } ?? item.text
        if let rtf = data(PasteType.rtf) { full.attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) }
        else if let rtfd = data(PasteType.rtfd) { full.attributed = NSAttributedString(rtfd: rtfd, documentAttributes: nil) }
        if item.kind == .image {
            full.image = reps.first(where: { PasteType.images.contains($0.type) }).flatMap { NSImage(data: $0.data) }
                ?? imageFile(of: item).flatMap(NSImage.init(contentsOf:))
        }
        return full
    }

    /// What a drag out of the shelf carries. Nothing is read when the drag starts: the types come from the item's
    /// kind and the bytes are read only if the other app asks for them.
    func itemProvider(_ item: Item) -> NSItemProvider {
        dragging = item
        if item.kind == .file || imageFile(of: item) != nil, let url = item.fileURLs.first, let provider = NSItemProvider(contentsOf: url) { return provider }
        let provider = NSItemProvider()
        let id = item.id
        let types: [String]
        switch item.kind {
        case .text, .color: types = [PasteType.plain]
        case .richText: types = [PasteType.rtf, PasteType.plain]
        case .link: types = [PasteType.url, PasteType.plain]
        case .image: types = [PasteType.png]
        case .file: types = []
        }
        for type in types {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { [store, storeQueue] done in
                storeQueue.async {
                    let reps = ((try? store.representations(id)) ?? []).filter { $0.index == 0 }
                    var data = reps.first { $0.type == type }?.data
                    if data == nil, type == PasteType.png, let image = reps.first(where: { PasteType.images.contains($0.type) }) {
                        data = NSBitmapImageRep(data: image.data)?.representation(using: .png, properties: [:])
                    }
                    if data == nil, type == PasteType.url { data = reps.first { $0.type == PasteType.plain }?.data }
                    done(data, nil)
                }
                return nil
            }
        }
        if let text = item.title ?? item.text { provider.suggestedName = String(text.prefix(40)) }
        return provider
    }

    /// Dropping a card on another one inside a pinboard moves it there.
    func moveDragged(onto target: Item) {
        defer { dragging = nil; dropTarget = nil }
        guard let board = pinboard, let moving = dragging, moving.id != target.id,
              let to = items.firstIndex(where: { $0.id == target.id }), let from = items.firstIndex(where: { $0.id == moving.id }) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            selection = items.firstIndex { $0.id == moving.id } ?? selection
        }
        let id = moving.id
        storeQueue.async { [store] in try? store.movePinned(id, in: board, to: to, now: Date()) }
    }
}

/// Reordering inside a pinboard: the card under the pointer shows where the dragged one will go.
struct ReorderDrop: DropDelegate {
    let target: Item
    let model: ShelfModel

    func validateDrop(info: DropInfo) -> Bool { model.pinboard != nil && model.dragging != nil }
    func dropEntered(info: DropInfo) { if validateDrop(info: info), model.dragging?.id != target.id { model.dropTarget = target.id } }
    func dropExited(info: DropInfo) { if model.dropTarget == target.id { model.dropTarget = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: validateDrop(info: info) ? .move : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        model.moveDragged(onto: target)
        return true
    }
}

/// What is shown under the pointer while dragging: small, so the drag stays smooth.
struct DragPreview: View {
    let item: Item
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(item.title ?? item.preview).font(.system(size: 12)).lineLimit(2)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
    }

    private var icon: String {
        switch item.kind {
        case .text, .richText: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        case .link: return "link"
        case .color: return "paintpalette"
        }
    }
}

// MARK: menu

/// The card's context menu. Built from data the model already has: no store reads while cards redraw.
struct CardMenu: View {
    let item: Item
    let model: ShelfModel

    var body: some View {
        Button("Paste") { model.perform(.paste(item, plainText: false)) }
        Button("Paste as Plain Text") { model.perform(.paste(item, plainText: true)) }
        Button("Copy") { model.perform(.copy(item)) }
        Divider()
        Button("Preview") { model.overlay = .preview(item) }
        if item.kind == .text || item.kind == .richText {
            Button("Edit") { model.overlay = .preview(item); model.editing = true }
        } else if item.kind == .image {
            Button("Edit in Preview") { model.perform(.editImage(item)) }
        }
        Button("Rename") { model.overlay = .rename(item) }
        Menu("Pin to") {
            ForEach(model.pinboards) { board in Button(board.name) { model.pin(item, to: board.id) } }
            if !model.pinboards.isEmpty { Divider() }
            Button("New Pinboard") { model.overlay = .newPinboard(pinning: item) }
        }
        Divider()
        if let board = model.pinboards.first(where: { $0.id == model.pinboard }) {
            Button("Remove from \(board.name)") { model.removeFromCurrent(item) }
        } else {
            Button("Remove from History") { model.removeFromCurrent(item) }
        }
        Button("Delete Everywhere") { model.deleteEverywhere(item) }
    }
}
