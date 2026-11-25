import AppKit

/// Edits an image in Preview: writes it to a file, opens it there, and when Preview saves, puts the edited image
/// back into the same item (same id, pins and place in History). Watching stops an hour after the last open.
@MainActor
final class ImageEditor {
    private let store: Store
    private let storeQueue: DispatchQueue
    private let onUpdate: () -> Void
    private let folder: URL
    private var sessions: [URL: (id: UUID, modified: Date, opened: Date)] = [:]
    private var watcher: DispatchSourceFileSystemObject?
    private var poll: Timer?

    init(store: Store, storeQueue: DispatchQueue, onUpdate: @escaping () -> Void) {
        self.store = store
        self.storeQueue = storeQueue
        self.onUpdate = onUpdate
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.mneme/Edits", isDirectory: true)
    }

    func edit(_ item: Item) {
        let id = item.id, folder = folder
        storeQueue.async { [store] in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let reps = (try? store.representations(id)) ?? []
            guard let rep = reps.first(where: { PasteType.images.contains($0.type) })
                ?? imageFile(of: item).flatMap({ try? Data(contentsOf: $0) }).map({ Representation(type: "file", data: $0) }) else { return }
            let png = rep.type == PasteType.png ? rep.data
                : NSBitmapImageRep(data: rep.data)?.representation(using: .png, properties: [:]) ?? rep.data
            let name = (item.title ?? "Mneme image").replacingOccurrences(of: "/", with: "-")
            let url = folder.appendingPathComponent("\(name) \(id.uuidString.prefix(8)).png")
            guard (try? png.write(to: url, options: .atomic)) != nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.sessions[url] = (id, Self.modified(url) ?? Date(), Date())
                    self.startWatching()
                    let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
                    NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The folder is watched (Preview saves by replacing the file); a slow poll is the fallback.
    private func startWatching() {
        if watcher == nil {
            let fd = open(folder.path, O_EVTONLY)
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
                source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.check() } }
                source.setCancelHandler { close(fd) }
                source.resume()
                watcher = source
            }
        }
        if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        }
    }

    private func check() {
        for (url, s) in sessions {
            if Date().timeIntervalSince(s.opened) > 3600 {
                sessions[url] = nil
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let m = Self.modified(url), m > s.modified, let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            sessions[url]?.modified = m
            let id = s.id
            storeQueue.async { [store] in
                guard (try? store.replaceImage(id, png: data, now: Date())) != nil, let item = try? store.item(id) else { return }
                storeThumbnail(store, item, imageData: data)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.onUpdate() } }
            }
        }
        if sessions.isEmpty {
            watcher?.cancel(); watcher = nil
            poll?.invalidate(); poll = nil
        }
    }
}
