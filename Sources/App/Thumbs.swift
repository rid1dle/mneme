import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A PNG thumbnail at most `maxPixel` on its long side, plus the image's real size. nil when the data is not an image.
func makeThumbnail(data: Data, maxPixel: Int = 400) -> (png: Data, width: Int, height: Int)? {
    guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    return makeThumbnail(source: src, maxPixel: maxPixel)
}

/// Straight from an image file, without reading it all into memory.
func makeThumbnail(url: URL, maxPixel: Int = 400) -> (png: Data, width: Int, height: Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    return makeThumbnail(source: src, maxPixel: maxPixel)
}

/// For an item that is one image file: the file while it exists (the pasteboard image may be only its icon).
func imageFile(of item: Item) -> URL? {
    guard item.kind == .image, item.fileURLs.count == 1, let url = item.fileURLs.first,
          FileManager.default.isReadableFile(atPath: url.path) else { return nil }
    return url
}

private func makeThumbnail(source src: CGImageSource, maxPixel: Int) -> (png: Data, width: Int, height: Int)? {
    guard
          CGImageSourceGetCount(src) > 0,
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
          let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, max(width, height)),
          ] as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, thumb, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return (out as Data, width, height)
}

/// Makes and stores the thumbnail of an image item; returns the item with its thumb and size set. Store queue only.
@discardableResult
func storeThumbnail(_ store: Store, _ item: Item, imageData: Data?) -> Item {
    var item = item
    // The image that came with the copy first: reading the file could make macOS ask for folder access (Desktop).
    guard let t = imageData.flatMap({ makeThumbnail(data: $0) }) ?? imageFile(of: item).flatMap({ makeThumbnail(url: $0) }) else { return item }
    let name = "\(item.hash.replacingOccurrences(of: ":", with: "-")).png"
    guard (try? t.png.write(to: store.thumbs.appendingPathComponent(name), options: .atomic)) != nil,
          (try? store.setThumb(item.id, name: name, width: t.width, height: t.height)) != nil else { return item }
    item.thumb = name; item.width = t.width; item.height = t.height
    return item
}
