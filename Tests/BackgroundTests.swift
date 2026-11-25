import Foundation

private let page = URL(string: "https://example.com/blog/post")!

let backgroundTests: [TestCase] = [
    test("should prefer the og title over the page title") {
        let html = "<html><head><title>Plain title</title><meta property=\"og:title\" content=\"Shared title\"></head><body>x</body></html>"
        expectEqual(parseLinkMeta(html: html, base: page).title, "Shared title")
        expectEqual(parseLinkMeta(html: "<head><title> Plain\n  title </title></head>", base: page).title, "Plain title")
    },
    test("should resolve a relative preview image against the page address") {
        let html = "<head><meta property='og:image' content='/img/card.png'></head>"
        expectEqual(parseLinkMeta(html: html, base: page).image?.absoluteString, "https://example.com/img/card.png")
        let abs = "<head><meta name=\"twitter:image\" content=\"https://cdn.example.net/a.jpg\"></head>"
        expectEqual(parseLinkMeta(html: abs, base: page).image?.absoluteString, "https://cdn.example.net/a.jpg")
    },
    test("should read meta attributes in any order and either quote style") {
        let html = "<head><meta content=\"Reversed\" property=\"og:title\"/><meta content='x.png' property='og:image'></head>"
        let meta = parseLinkMeta(html: html, base: page)
        expectEqual(meta.title, "Reversed")
        expectEqual(meta.image?.lastPathComponent, "x.png")
    },
    test("should decode entities in titles") {
        let html = "<head><title>Tom &amp; Jerry&#39;s &quot;Best&quot; &#x2014; Part&nbsp;2</title></head>"
        expectEqual(parseLinkMeta(html: html, base: page).title, "Tom & Jerry's \"Best\" \u{2014} Part 2")
    },
    test("should return nothing for a page without a title or preview image") {
        let meta = parseLinkMeta(html: "not html at all <<<", base: page)
        expect(meta.title == nil && meta.image == nil)
        expect(parseLinkMeta(html: "<head><meta property=\"og:image\" content=\"javascript:alert(1)\"></head>", base: page).image == nil)
    },
    test("should allow background work only when idle a minute and the Mac is cool") {
        expectEqual(mayRunBackgroundWork(idleSeconds: 59, thermal: .nominal), false)
        expectEqual(mayRunBackgroundWork(idleSeconds: 60, thermal: .nominal), true)
        expectEqual(mayRunBackgroundWork(idleSeconds: 600, thermal: .fair), true)
        expectEqual(mayRunBackgroundWork(idleSeconds: 600, thermal: .serious), false)
    },
    test("should read a just-copied image only while the Mac is cool") {
        expectEqual(mayReadNewImage(thermal: .nominal), true)
        expectEqual(mayReadNewImage(thermal: .fair), true)
        expectEqual(mayReadNewImage(thermal: .serious), false)
        expectEqual(mayReadNewImage(thermal: .critical), false)
    },
]
