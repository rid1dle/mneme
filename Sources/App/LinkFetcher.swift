import Foundation

/// Fetches a copied link's page title and preview image: only the start of the page (up to the end of <head>,
/// at most 256 KB), the image only if it is 1 MB or less, 5 s timeouts, no cookies. Off when the user turns it off.
@MainActor
final class LinkFetcher {
    private let store: Store
    private let storeQueue: DispatchQueue
    private let onFetched: () -> Void
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 8
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpAdditionalHeaders = ["User-Agent": "Mneme/0.1 (link preview)", "Accept": "text/html,application/xhtml+xml"]
        return URLSession(configuration: c)
    }()

    init(store: Store, storeQueue: DispatchQueue, onFetched: @escaping () -> Void) {
        self.store = store
        self.storeQueue = storeQueue
        self.onFetched = onFetched
    }

    func fetch(_ item: Item) {
        guard item.kind == .link, UserDefaults.standard.bool(forKey: Pref.linkPreviews),
              let url = URL(string: item.text ?? item.preview), shouldFetchPreview(url) else { return }
        let id = item.id, session = session
        Task.detached(priority: .utility) {
            guard let html = await Self.head(of: url, session: session) else { return }
            let meta = parseLinkMeta(html: html, base: url)
            var imageName: String?
            if let imageURL = meta.image, let data = await Self.small(imageURL, session: session), let t = makeThumbnail(data: data) {
                let name = "link-\(id.uuidString).png"
                if (try? t.png.write(to: self.store.blobs.appendingPathComponent(name), options: .atomic)) != nil { imageName = name }
            }
            guard meta.title != nil || imageName != nil else { return }
            self.storeQueue.async {
                try? self.store.setLinkPreview(id, title: meta.title, image: imageName)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.onFetched() } }
            }
        }
    }

    nonisolated private static func head(of url: URL, session: URLSession) async -> String? {
        guard let (bytes, response) = try? await session.bytes(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              (http.value(forHTTPHeaderField: "Content-Type") ?? "text/html").lowercased().contains("html") else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 256 * 1024 { break }
                if byte == UInt8(ascii: ">"), data.count > 7, data.suffix(7).lowercased() == "</head>" { break }
            }
        } catch {}
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    nonisolated private static func small(_ url: URL, session: URLSession) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.expectedContentLength <= 1_000_000 else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > 1_000_000 { return nil }
            }
        } catch { return nil }
        return data
    }
}

private extension Data {
    func lowercased() -> String { String(decoding: self, as: UTF8.self).lowercased() }
}
