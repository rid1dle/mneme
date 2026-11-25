import Foundation

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func ago(_ s: Double) -> Date { now.addingTimeInterval(-s) }
private let us = Locale(identifier: "en_US")
private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

private func item(_ kind: ItemKind, text: String? = nil, preview: String = "", chars: Int = 0, files: [URL] = [], w: Int? = nil, h: Int? = nil) -> Item {
    Item(id: UUID(), kind: kind, title: nil, text: text, preview: preview, hash: "", byteSize: 0, charCount: chars, source: nil, fileURLs: files,
         linkTitle: nil, linkImage: nil, ocrText: nil, thumb: nil, width: w, height: h, createdAt: now, updatedAt: now,
         lastUsedAt: now, inHistory: true, deletedAt: nil)
}

let formatTests: [TestCase] = [
    test("should say how long ago something was copied in a few characters") {
        // now is 2027-01-15 08:00 UTC
        expectEqual(relativeTime(ago(20), now: now, calendar: utc, locale: us), "Now")
        expectEqual(relativeTime(ago(125), now: now, calendar: utc, locale: us), "2m")
        expectEqual(relativeTime(ago(3 * 3600 + 5), now: now, calendar: utc, locale: us), "3h")
        expectEqual(relativeTime(ago(20 * 3600), now: now, calendar: utc, locale: us), "Yesterday")
        expectEqual(relativeTime(ago(4 * 86_400), now: now, calendar: utc, locale: us), "4d")
        expectEqual(relativeTime(ago(40 * 86_400), now: now, calendar: utc, locale: us), "Dec 6")
        expectEqual(relativeTime(ago(400 * 86_400), now: now, calendar: utc, locale: us), "Dec 11, 2025")
    },
    test("should say how long ago something was copied in words for the card header") {
        expectEqual(relativeTimeLong(ago(20), now: now, calendar: utc, locale: us), "Just now")
        expectEqual(relativeTimeLong(ago(65), now: now, calendar: utc, locale: us), "1 minute ago")
        expectEqual(relativeTimeLong(ago(5 * 60 + 10), now: now, calendar: utc, locale: us), "5 minutes ago")
        expectEqual(relativeTimeLong(ago(3600 + 5), now: now, calendar: utc, locale: us), "1 hour ago")
        expectEqual(relativeTimeLong(ago(3 * 3600 + 5), now: now, calendar: utc, locale: us), "3 hours ago")
        expectEqual(relativeTimeLong(ago(20 * 3600), now: now, calendar: utc, locale: us), "Yesterday")
        expectEqual(relativeTimeLong(ago(4 * 86_400), now: now, calendar: utc, locale: us), "4 days ago")
        expectEqual(relativeTimeLong(ago(40 * 86_400), now: now, calendar: utc, locale: us), "Dec 6")
    },
    test("should pick an app's colour from its icon, ignoring white, black and see-through pixels") {
        // 4 pixels: transparent, white, black, and VS Code blue twice as a 2x2 + 1 extra row
        let blue: [UInt8] = [0, 122, 204, 255]
        let px: [UInt8] = [0, 0, 0, 0] + [255, 255, 255, 255] + [0, 0, 0, 255] + blue + blue + blue
        let c = dominantColor(rgba: px, width: 3, height: 2)
        expectEqual(c.map { [$0.r, $0.g, $0.b] }, [0, 122, 204])
    },
    test("should darken a light app colour so white header text stays readable") {
        let yellow: [UInt8] = [255, 214, 10, 255]
        let c = headerColor(dominantColor(rgba: yellow + yellow, width: 2, height: 1))
        expect(c.map { contrastWithWhite($0) >= 4.5 } == true, "\(String(describing: c))")
    },
    test("should have no colour for an icon that is only white, black or clear") {
        expect(dominantColor(rgba: [255, 255, 255, 255, 0, 0, 0, 255, 9, 9, 9, 0], width: 3, height: 1) == nil)
    },
    test("should not show a future time when the clock moved back") {
        expectEqual(relativeTime(now.addingTimeInterval(300), now: now, calendar: utc, locale: us), "Now")
    },
    test("should describe each kind of item in its footer") {
        expectEqual(footerText(locale: us, item(.text, preview: "hello", chars: 5)), "5 characters")
        expectEqual(footerText(locale: us, item(.text, preview: "a", chars: 1)), "1 character")
        expectEqual(footerText(locale: us, item(.richText, preview: "x", chars: 2_140)), "2,140 characters")
        expectEqual(footerText(locale: us, item(.image, w: 1600, h: 900)), "1600 × 900")
        expectEqual(footerText(locale: us, item(.image)), "Image")
        expectEqual(footerText(locale: us, item(.file, files: [URL(fileURLWithPath: "/a")])), "1 file")
        expectEqual(footerText(locale: us, item(.file, files: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")])), "2 files")
        expectEqual(footerText(locale: us, item(.link, text: "https://www.example.com/a/b")), "example.com")
        expectEqual(footerText(locale: us, item(.color, preview: "#3A70C8")), "rgb(58, 112, 200)")
    },
]
