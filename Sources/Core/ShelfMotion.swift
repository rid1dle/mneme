import Foundation

/// How the shelf looks part way in or out: its opacity, how far below its resting place it sits (points) and its size.
public struct ShelfPose: Equatable, Sendable {
    public var opacity: Double
    public var drop: Double
    public var scale: Double
    public static let rest = ShelfPose(opacity: 1, drop: 0, scale: 1)
}

/// One way in or out. The values describe the hidden end; the other end is always `ShelfPose.rest`.
public struct ShelfMove: Equatable, Sendable {
    public var opacity: Double
    public var drop: Double
    /// Also drops by the shelf's own height, so it starts (or ends) below the bottom edge of the screen.
    public var offScreen = false
    public var scale = 1.0
    public var duration: Double
    public var curve: [Double]
    public var fadeDuration: Double
    public var fadeCurve: [Double]

    public func drop(shelfHeight: Double, pointScale: Double = 1) -> Double {
        drop * pointScale + (offScreen ? shelfHeight : 0)
    }

    public var length: Double { max(opacity < 1 ? fadeDuration : 0, drop != 0 || offScreen || scale != 1 ? duration : 0) }

    public func hidden(shelfHeight: Double, pointScale: Double = 1) -> ShelfPose {
        ShelfPose(opacity: opacity, drop: drop(shelfHeight: shelfHeight, pointScale: pointScale), scale: scale)
    }

    /// `t` seconds in; opening goes from hidden to rest, closing from rest to hidden. `pointScale` shrinks the fixed
    /// distances for a small preview.
    public func pose(at t: Double, opening: Bool, shelfHeight: Double, pointScale: Double = 1) -> ShelfPose {
        let h = hidden(shelfHeight: shelfHeight, pointScale: pointScale)
        let (from, to) = opening ? (h, ShelfPose.rest) : (ShelfPose.rest, h)
        let m = cubicBezier(curve, at: duration > 0 ? t / duration : 1)
        let f = cubicBezier(fadeCurve, at: fadeDuration > 0 ? t / fadeDuration : 1)
        return ShelfPose(opacity: from.opacity + (to.opacity - from.opacity) * f,
                         drop: from.drop + (to.drop - from.drop) * m,
                         scale: from.scale + (to.scale - from.scale) * m)
    }
}

public enum ShelfMotion: String, CaseIterable, Sendable {
    case rise, drawer, fade, zoom

    public static let standard = ShelfMotion.rise

    /// A saved choice; anything unknown reads as the standard one.
    public init(saved: String?) { self = saved.flatMap(ShelfMotion.init(rawValue:)) ?? .standard }

    public var name: String {
        switch self {
        case .rise: return "Rise"
        case .drawer: return "Drawer"
        case .fade: return "Fade"
        case .zoom: return "Zoom"
        }
    }

    public var detail: String {
        switch self {
        case .rise: return "Rises a little as it fades in, and sinks as it fades out."
        case .drawer: return "Slides all the way up from the bottom edge of the screen, and back down."
        case .fade: return "Fades in and out in place, with no movement."
        case .zoom: return "Grows from slightly smaller as it fades in, and shrinks as it fades out."
        }
    }

    static let easeOut = [0, 0, 0.58, 1.0]
    static let easeIn = [0.42, 0, 1, 1.0]
    static let settle = [0.16, 1, 0.3, 1.0]

    /// 8 points above the screen's bottom edge plus room for the shadow under it: a drawer drops this far more than
    /// its height to be fully out of sight.
    static let belowEdge = 32.0

    public var open: ShelfMove {
        switch self {
        case .rise: return ShelfMove(opacity: 0, drop: 16, duration: 0.28, curve: Self.settle, fadeDuration: 0.18, fadeCurve: Self.easeOut)
        case .drawer: return ShelfMove(opacity: 1, drop: Self.belowEdge, offScreen: true, duration: 0.34, curve: [0.22, 1, 0.36, 1], fadeDuration: 0, fadeCurve: Self.easeOut)
        case .fade: return ShelfMove(opacity: 0, drop: 0, duration: 0, curve: Self.easeOut, fadeDuration: 0.2, fadeCurve: Self.easeOut)
        case .zoom: return ShelfMove(opacity: 0, drop: 0, scale: 0.92, duration: 0.26, curve: Self.settle, fadeDuration: 0.16, fadeCurve: Self.easeOut)
        }
    }

    /// Closing is quicker than opening, so the app underneath is back at once.
    public var close: ShelfMove {
        switch self {
        case .rise: return ShelfMove(opacity: 0, drop: 12, duration: 0.14, curve: Self.easeIn, fadeDuration: 0.14, fadeCurve: Self.easeIn)
        case .drawer: return ShelfMove(opacity: 1, drop: Self.belowEdge, offScreen: true, duration: 0.22, curve: [0.55, 0, 1, 0.45], fadeDuration: 0, fadeCurve: Self.easeIn)
        case .fade: return ShelfMove(opacity: 0, drop: 0, duration: 0, curve: Self.easeIn, fadeDuration: 0.14, fadeCurve: Self.easeIn)
        case .zoom: return ShelfMove(opacity: 0, drop: 0, scale: 0.96, duration: 0.14, curve: Self.easeIn, fadeDuration: 0.14, fadeCurve: Self.easeIn)
        }
    }

    static let loopHidden = 0.5
    static let loopOpen = 1.4

    /// One preview loop: hidden, opening, open, closing.
    public var loopLength: Double { Self.loopHidden + open.length + Self.loopOpen + close.length }

    /// The pose for the looping preview in Settings, `t` seconds after it started playing.
    public func loopPose(at t: Double, shelfHeight: Double, pointScale: Double = 1) -> ShelfPose {
        var t = t.truncatingRemainder(dividingBy: loopLength)
        if t < 0 { t += loopLength }
        let hidden = open.hidden(shelfHeight: shelfHeight, pointScale: pointScale)
        if t < Self.loopHidden { return hidden }
        t -= Self.loopHidden
        if t < open.length { return open.pose(at: t, opening: true, shelfHeight: shelfHeight, pointScale: pointScale) }
        t -= open.length
        if t < Self.loopOpen { return .rest }
        t -= Self.loopOpen
        return close.pose(at: min(t, close.length), opening: false, shelfHeight: shelfHeight, pointScale: pointScale)
    }
}

/// CSS-style cubic Bézier timing curve through (0,0), (x1,y1), (x2,y2), (1,1): progress at time fraction `x`.
public func cubicBezier(_ c: [Double], at x: Double) -> Double {
    guard x > 0 else { return 0 }
    guard x < 1 else { return 1 }
    let (x1, y1, x2, y2) = (c[0], c[1], c[2], c[3])
    func bez(_ s: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
    }
    var lo = 0.0, hi = 1.0, s = x
    for _ in 0..<40 {
        let v = bez(s, x1, x2)
        if abs(v - x) < 1e-7 { break }
        if v < x { lo = s } else { hi = s }
        s = (lo + hi) / 2
    }
    return bez(s, y1, y2)
}
