import Foundation

public struct RGB: Equatable, Hashable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// The most common clearly coloured pixel group of an icon (RGBA, 8 bits each). Pixels that are mostly clear, or
/// grey, white or black (little difference between channels), are ignored. nil when nothing coloured is left.
public func dominantColor(rgba: [UInt8], width: Int, height: Int) -> RGB? {
    var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
    let n = min(width * height, rgba.count / 4)
    for i in 0..<n {
        let p = i * 4
        let (r, g, b, a) = (Int(rgba[p]), Int(rgba[p + 1]), Int(rgba[p + 2]), Int(rgba[p + 3]))
        guard a >= 128, max(r, g, b) - min(r, g, b) >= 40 else { continue }
        let key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5)
        let e = buckets[key] ?? (0, 0, 0, 0)
        buckets[key] = (e.count + 1, e.r + r, e.g + g, e.b + b)
    }
    guard let best = buckets.values.max(by: { $0.count < $1.count }) else { return nil }
    return RGB(r: UInt8(best.r / best.count), g: UInt8(best.g / best.count), b: UInt8(best.b / best.count))
}

/// WCAG contrast ratio of white text on this colour.
public func contrastWithWhite(_ c: RGB) -> Double {
    func lin(_ v: UInt8) -> Double {
        let s = Double(v) / 255
        return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    let l = 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    return 1.05 / (l + 0.05)
}

/// The colour darkened just enough for white header text to read (contrast 4.5 or more).
public func headerColor(_ c: RGB?) -> RGB? {
    guard var c else { return nil }
    while contrastWithWhite(c) < 4.5 {
        c = RGB(r: UInt8(Double(c.r) * 0.92), g: UInt8(Double(c.g) * 0.92), b: UInt8(Double(c.b) * 0.92))
    }
    return c
}
