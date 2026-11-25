import AppKit

enum Snapshot {
    typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// The window as the system composites it (glass included), captured by its own window number only, which needs
    /// no Screen Recording permission. Falls back to the view drawing itself.
    @MainActor
    static func write(_ window: NSWindow, to path: String) {
        var data: Data?
        if let number = UInt32(exactly: window.windowNumber), number > 0,
           let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(sym, to: WindowImage.self)
            // IncludingWindow (1 << 3) with ImageBoundsIgnoreFraming (1 << 0): this window only.
            if let img = create(.null, 1 << 3, number, 1 << 0)?.takeRetainedValue(), img.width > 10 {
                data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
            }
        }
        if data == nil, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        if let data { try? data.write(to: URL(fileURLWithPath: path)) }
        FileHandle.standardError.write("snapshot: \(data == nil ? "failed" : path)\n".data(using: .utf8)!)
    }
}
