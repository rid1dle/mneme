import AppKit
import SwiftUI

enum DateFilter: String, CaseIterable {
    case any = "Any time", today = "Today", week = "Last 7 days", month = "Last 30 days"

    func since(now: Date = Date()) -> Date? {
        switch self {
        case .any: return nil
        case .today: return Calendar.current.startOfDay(for: now)
        case .week: return now.addingTimeInterval(-7 * 86_400)
        case .month: return now.addingTimeInterval(-30 * 86_400)
        }
    }
}

enum Overlay: Equatable {
    case preview(Item)
    case rename(Item)
    case newPinboard(pinning: Item?)
    case confirmDelete(Item, pinboards: Int)
}

/// What the controller does for the views (they cannot reach the pasteboard or other apps themselves).
enum ShelfCommand {
    case paste(Item, plainText: Bool)
    case copy(Item)
    case editImage(Item)
    case stopStack
    case openSettings
}

/// What the shelf shows. Lives as long as the app, but holds items and images only while the shelf is open.
@MainActor
final class ShelfModel: ObservableObject {
    @Published var searchText = "" { didSet { if !quiet { scheduleReload(debounce: true) } } }
    @Published var kinds: Set<ItemKind> = [] { didSet { if !quiet { scheduleReload() } } }
    @Published var sourceBundleID: String? { didSet { if !quiet { scheduleReload() } } }
    @Published var dateFilter: DateFilter = .any { didSet { if !quiet { scheduleReload() } } }
    @Published var pinboard: UUID? { didSet { if !quiet { scheduleReload() } } }
    @Published var items: [Item] = []
    @Published var selection = 0
    @Published private(set) var pinboards: [Pinboard] = []
    @Published private(set) var apps: [SourceApp] = []
    @Published private(set) var loaded = false
    @Published var captureAllowed = true
    @Published var overlay: Overlay?
    @Published var editing = false
    @Published var dropTarget: UUID?
    var dragging: Item?
    @Published private(set) var stackOn = false
    @Published private(set) var stackItems: [Item] = []
    private var stackIDs: [UUID] = []
    var perform: (ShelfCommand) -> Void = { _ in }

    let store: Store
    let storeQueue: DispatchQueue
    let pageSize = 60
    private var generation = 0
    private var exhausted = false
    private var loadingMore = false
    private var pending: DispatchWorkItem?
    private var quiet = false
    private let thumbCache = NSCache<NSString, NSImage>()
    private let iconCache = NSCache<NSString, NSImage>()
    /// Tiny (one colour per app), so it is kept across opens.
    private var colorCache: [String: Color?] = [:]
    private let imageQueue = DispatchQueue(label: "local.mneme.images", qos: .userInitiated, attributes: .concurrent)

    init(store: Store, storeQueue: DispatchQueue) {
        self.store = store
        self.storeQueue = storeQueue
        thumbCache.totalCostLimit = 32 * 1024 * 1024
    }

    var query: Query {
        var q = Query()
        q.text = searchText
        q.kinds = kinds
        q.sourceBundleID = sourceBundleID
        q.since = dateFilter.since()
        q.pinboard = pinboard
        return q
    }

    var selectedItem: Item? { items.indices.contains(selection) ? items[selection] : nil }

    private func scheduleReload(debounce: Bool = false) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.08 : 0), execute: work)
    }

    /// Loads the first page (and the pinboard, app and stack lists), then calls `done` on the main thread.
    /// `keepSelection` keeps the selected position (after an action on an item) instead of going back to the first.
    func reload(keepSelection: Bool = false, done: (() -> Void)? = nil) {
        generation += 1
        let g = generation, q = query, ids = stackIDs
        let size = keepSelection ? max(pageSize, items.count) : pageSize
        let keep = keepSelection ? selection : 0
        storeQueue.async { [store] in
            let page = (try? store.page(q, offset: 0, limit: size)) ?? []
            let boards = (try? store.allPinboards()) ?? []
            let apps = (try? store.sourceApps()) ?? []
            let stack = ids.compactMap { try? store.item($0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard g == self.generation else { return }
                    if self.pinboard != nil, !boards.contains(where: { $0.id == self.pinboard }) { self.quietly { self.pinboard = nil } }
                    self.items = page
                    self.pinboards = boards
                    self.apps = apps
                    self.stackItems = stack
                    self.selection = min(keep, max(page.count - 1, 0))
                    self.exhausted = page.count < size
                    self.loaded = true
                    done?()
                }
            }
        }
    }

    func loadMore() {
        guard loaded, !exhausted, !loadingMore else { return }
        loadingMore = true
        let g = generation, q = query, offset = items.count, size = pageSize
        storeQueue.async { [store] in
            let page = (try? store.page(q, offset: offset, limit: size)) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loadingMore = false
                    guard g == self.generation else { return }
                    self.items += page
                    self.exhausted = page.count < size
                }
            }
        }
    }

    /// Called by the app when the paste stack changes; the strip refreshes if the shelf is open.
    func setStack(on: Bool, ids: [UUID]) {
        stackOn = on
        stackIDs = ids
        guard loaded else { return }
        storeQueue.async { [store] in
            let items = ids.compactMap { try? store.item($0) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.stackItems = items } }
        }
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(selection + delta, 0), items.count - 1)
        if selection >= items.count - 10 { loadMore() }
    }

    private func quietly(_ body: () -> Void) {
        quiet = true
        body()
        quiet = false
    }

    /// Called when the shelf closes: drop everything that costs memory and reset the filters for next time.
    func releaseCaches() {
        generation += 1
        pending?.cancel()
        quietly {
            searchText = ""
            kinds = []
            sourceBundleID = nil
            dateFilter = .any
        }
        items = []
        stackItems = []
        overlay = nil
        editing = false
        dragging = nil
        dropTarget = nil
        loaded = false
        thumbCache.removeAllObjects()
        iconCache.removeAllObjects()
        missingCache = [:]
    }

    // MARK: images

    func thumbnail(_ item: Item) async -> NSImage? {
        guard let name = item.thumb else { return nil }
        if let cached = thumbCache.object(forKey: name as NSString) { return cached }
        let url = store.thumbs.appendingPathComponent(name)
        let image: NSImage? = await withCheckedContinuation { cont in
            imageQueue.async { cont.resume(returning: NSImage(contentsOf: url)) }
        }
        if let image {
            let cost = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 } ?? 0
            thumbCache.setObject(image, forKey: name as NSString, cost: cost)
        }
        return image
    }

    /// The header colour for an app: its icon's main colour, darkened until white text reads on it.
    func appColor(_ bundleID: String?) -> Color? {
        guard let bundleID else { return nil }
        if let cached = colorCache[bundleID] { return cached }
        var color: Color?
        if let icon = appIcon(bundleID) {
            let size = 32
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)
            if let rep, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
                NSGraphicsContext.restoreGraphicsState()
                if let data = rep.bitmapData {
                    let bytes = Array(UnsafeBufferPointer(start: data, count: size * size * 4))
                    if let c = headerColor(dominantColor(rgba: bytes, width: size, height: size)) {
                        color = Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
                    }
                }
            }
        }
        colorCache[bundleID] = color
        return color
    }

    private var missingCache: [UUID: Bool] = [:]

    /// Checked once per open, not on every redraw.
    func filesMissing(_ item: Item) -> Bool {
        if let cached = missingCache[item.id] { return cached }
        let missing = item.fileURLs.contains { !FileManager.default.fileExists(atPath: $0.path) }
        missingCache[item.id] = missing
        return missing
    }

    func fileIcon(_ item: Item) -> NSImage? {
        guard let first = item.fileURLs.first else { return nil }
        let key = "file:" + first.pathExtension.lowercased() + (first.hasDirectoryPath ? "/" : "")
        if let cached = iconCache.object(forKey: key as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: first.path)
        icon.size = NSSize(width: 64, height: 64)
        if FileManager.default.fileExists(atPath: first.path) { iconCache.setObject(icon, forKey: key as NSString) }
        return icon
    }

    func linkImage(_ item: Item) async -> NSImage? {
        guard let name = item.linkImage else { return nil }
        let key = "link:" + name
        if let cached = thumbCache.object(forKey: key as NSString) { return cached }
        let url = store.blobs.appendingPathComponent(name)
        let image: NSImage? = await withCheckedContinuation { cont in imageQueue.async { cont.resume(returning: NSImage(contentsOf: url)) } }
        if let image { thumbCache.setObject(image, forKey: key as NSString, cost: 400 * 300 * 4) }
        return image
    }

    func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = iconCache.object(forKey: bundleID as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        iconCache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}
