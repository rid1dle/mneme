import Foundation

private func near(_ a: Double, _ b: Double, _ tol: Double = 0.001) -> Bool { abs(a - b) < tol }

let shelfMotionTests: [TestCase] = [
    test("should keep the rise the shelf already had as the standard style") {
        expectEqual(ShelfMotion.standard, .rise)
        let open = ShelfMotion.rise.open
        expectEqual(open.drop, 16)
        expectEqual(open.duration, 0.28)
        expectEqual(open.fadeDuration, 0.18)
        expectEqual(ShelfMotion.rise.close.drop, 12)
    },
    test("should read an unknown or missing saved style as the standard one") {
        expectEqual(ShelfMotion(saved: nil), .rise)
        expectEqual(ShelfMotion(saved: "spin"), .rise)
        expectEqual(ShelfMotion(saved: "drawer"), .drawer)
    },
    test("should start every opening at its hidden pose and end it at rest") {
        for m in ShelfMotion.allCases {
            let start = m.open.pose(at: 0, opening: true, shelfHeight: 230)
            expectEqual(start, m.open.hidden(shelfHeight: 230), m.rawValue)
            expectEqual(m.open.pose(at: m.open.length, opening: true, shelfHeight: 230), .rest, m.rawValue)
        }
    },
    test("should end every closing out of sight or faded") {
        for m in ShelfMotion.allCases {
            let end = m.close.pose(at: m.close.length, opening: false, shelfHeight: 230)
            expectEqual(m.close.pose(at: 0, opening: false, shelfHeight: 230), .rest, m.rawValue)
            expect(end.opacity == 0 || end.drop >= 230, "\(m.rawValue) ends visible: \(end)")
        }
    },
    test("should make each style look different from the others") {
        let mid = ShelfMotion.allCases.map { $0.open.pose(at: 0.05, opening: true, shelfHeight: 230) }
        expectEqual(Set(mid.map { "\($0.opacity)|\($0.drop)|\($0.scale)" }).count, ShelfMotion.allCases.count)
    },
    test("should start the drawer fully below the bottom edge whatever the shelf's height") {
        for h in [150.0, 230, 400] {
            let start = ShelfMotion.drawer.open.hidden(shelfHeight: h)
            expect(start.drop >= h + 8, "height \(h) drops \(start.drop)")
            expectEqual(start.opacity, 1, "the drawer does not fade")
        }
    },
    test("should close at least as quickly as it opens") {
        for m in ShelfMotion.allCases { expect(m.close.length <= m.open.length, m.rawValue) }
    },
    test("should keep every style short enough to never feel slow") {
        for m in ShelfMotion.allCases { expect(m.open.length > 0.1 && m.open.length <= 0.4, "\(m.rawValue) \(m.open.length)") }
    },
    test("should ease from 0 to 1 without ever stepping back") {
        for c in [ShelfMotion.settle, ShelfMotion.easeIn, ShelfMotion.easeOut, [0.22, 1, 0.36, 1], [0.55, 0, 1, 0.45]] {
            expectEqual(cubicBezier(c, at: 0), 0)
            expectEqual(cubicBezier(c, at: 1), 1)
            var last = 0.0
            for i in 1...100 {
                let v = cubicBezier(c, at: Double(i) / 100)
                expect(v >= last - 1e-9, "\(c) steps back at \(i)")
                last = v
            }
        }
    },
    test("should follow the known timing curves") {
        expect(near(cubicBezier([0.42, 0, 0.58, 1], at: 0.5), 0.5))
        expect(near(cubicBezier([0, 0, 1, 1], at: 0.3), 0.3))
        expect(cubicBezier(ShelfMotion.easeOut, at: 0.5) > 0.5, "ease out is past half way at half time")
        expect(cubicBezier(ShelfMotion.easeIn, at: 0.5) < 0.5, "ease in is short of half way at half time")
        expectEqual(cubicBezier([0, 0, 1, 1], at: -2), 0, "times before the start clamp")
    },
    test("should loop the preview hidden, opening, open, closing and then repeat") {
        let m = ShelfMotion.zoom
        expectEqual(m.loopPose(at: 0, shelfHeight: 30), m.open.hidden(shelfHeight: 30))
        let openAt = ShelfMotion.loopHidden + m.open.length + ShelfMotion.loopOpen / 2
        expectEqual(m.loopPose(at: openAt, shelfHeight: 30), .rest)
        expectEqual(m.loopPose(at: openAt + m.loopLength * 3, shelfHeight: 30), .rest, "repeats")
        let closed = m.loopPose(at: m.loopLength - 0.0001, shelfHeight: 30)
        expect(closed.opacity < 0.05, "faded out at the end of the loop: \(closed)")
    },
    test("should shrink fixed distances for the small preview but keep the drawer out of sight") {
        expectEqual(ShelfMotion.rise.open.hidden(shelfHeight: 24, pointScale: 0.5).drop, 8)
        expect(ShelfMotion.drawer.open.hidden(shelfHeight: 24, pointScale: 0.25).drop >= 24 + 8)
    },
    test("should default to the standard style in settings") {
        let d = UserDefaults(suiteName: "mneme-motion-\(UUID().uuidString)")!
        Pref.register(d)
        expectEqual(ShelfMotion(saved: d.string(forKey: Pref.shelfMotion)), .rise)
    },
]
