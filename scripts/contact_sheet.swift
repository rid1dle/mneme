// Stacks PNGs into one sheet for review: contact_sheet <out.png> <width> <in.png>...
import AppKit
let a = CommandLine.arguments
let width = CGFloat(Double(a[2])!)
let images = a.dropFirst(3).compactMap { p -> (String, NSImage)? in NSImage(contentsOfFile: p).map { ((p as NSString).lastPathComponent, $0) } }
let heights = images.map { width * $0.1.size.height / $0.1.size.width + 26 }
let total = heights.reduce(0, +)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(total), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.5, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: total).fill()
var y = total
for ((name, img), h) in zip(images, heights) {
    y -= h
    (name as NSString).draw(at: NSPoint(x: 6, y: y + h - 22), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white])
    img.draw(in: NSRect(x: 0, y: y, width: width, height: h - 26))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
