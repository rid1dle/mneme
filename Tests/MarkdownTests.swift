import AppKit

/// The shape of a reply copied from VS Code's chat panel: theme colours, bold labels with Chromium's spacer spans,
/// a table, a numbered list with a nested list, inline code, a link and a code block.
private let chatReply = """
<meta charset='utf-8'><p style="white-space: pre-wrap; color: rgb(248, 248, 242); background-color: rgb(33, 34, 44);">Done.</p>\
<p style="white-space: pre-wrap; color: rgb(248, 248, 242);"><strong>What changed (run 51e6):</strong></p>\
<table style="color: rgb(248, 248, 242);"><thead><tr><th style="padding: 2px;">Request</th><th>Now</th></tr></thead>\
<tbody><tr><td>"Fill it"</td><td>checks 12,154 rows</td></tr><tr><td>a | b</td><td>(no card)</td></tr></tbody></table>\
<ol style="padding-inline-start: 2em;"><li><strong>Fixed:</strong><span> </span>the <code>mapping</code> finding.<ul><li>inner</li></ul></li>\
<li>See <a href="https://example.com/a">the doc</a> and <a href="https://example.com/b">https://example.com/b</a>.</li></ol>\
<pre><code>let a = 1\n  b *c*</code></pre>
"""

private let chatReplyMarkdown = """
Done.

**What changed (run 51e6):**

| Request | Now |
| --- | --- |
| "Fill it" | checks 12,154 rows |
| a \\| b | (no card) |

1. **Fixed:** the `mapping` finding.
   - inner
2. See [the doc](https://example.com/a) and https://example.com/b.

```
let a = 1
  b *c*
```
"""

private let editorCode = """
<meta charset="utf-8"><div style="color: #d4d4d4;background-color: #1e1e1e;font-family: Menlo, monospace;white-space: pre;"><div><span style="color: #569cd6;font-weight: bold;">if</span> (a &lt; b) {</div><div>    <span style="color: #dcdcaa;">run</span>();</div><div>}</div></div>
"""

private struct Board {
    let pb = NSPasteboard(name: NSPasteboard.Name("mneme-md-test-\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "mneme-md-\(UUID().uuidString)")!
    let formatter: PasteFormatter

    init() {
        Pref.register(defaults)
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("mneme-md-log-\(UUID().uuidString).jsonl")
        formatter = PasteFormatter(pasteboard: pb, defaults: defaults, logURL: log)
    }

    @discardableResult
    func copy(_ reps: [Representation], from source: String) -> Int {
        pb.clearContents()
        let item = NSPasteboardItem()
        for r in reps { item.setData(r.data, forType: NSPasteboard.PasteboardType(r.type)) }
        pb.writeObjects([item])
        formatter.copied(reps, source: SourceApp(bundleID: source, name: source), changeCount: pb.changeCount)
        formatter.settle()
        return pb.changeCount
    }

    func press(into bundle: String) {
        formatter.setFront(bundle: bundle, name: bundle, pid: 0)
        formatter.commandV()
    }

    func string(_ t: String) -> String? { pb.string(forType: NSPasteboard.PasteboardType(t)) }
}

private func copyOf(_ html: String, plain: String, extra: String? = nil) -> [Representation] {
    var reps = [Representation(type: PasteType.html, data: Data(html.utf8)), Representation(type: PasteType.plain, data: Data(plain.utf8))]
    if let extra { reps.append(Representation(type: extra, data: Data("{}".utf8))) }
    return reps
}

let markdownTests: [TestCase] = [
    test("should write a chat reply's bold, table, numbered and nested lists, code, links and code block as Markdown") {
        expectEqual(markdownText(fromHTML: chatReply), chatReplyMarkdown)
    },
    test("should return nil for a code editor's copy and for prose with nothing only Markdown carries") {
        expect(markdownText(fromHTML: editorCode) == nil, markdownText(fromHTML: editorCode) ?? "")
        expect(markdownText(fromHTML: "<p style=\"color:red\">Just a line.</p><p>Another.</p>") == nil)
    },
    test("should move spaces inside bold outside its markers and drop empty bold") {
        expectEqual(markdownText(fromHTML: "<p>a<strong> b </strong>c<strong> </strong>d</p>"), "a **b** c d")
    },
    test("should turn styled bold and italic into Markdown like cleaning does") {
        expectEqual(markdownText(fromHTML: "<p><span style=\"font-weight:700\">Bold</span> and <span style=\"font-style:italic\">it</span></p>"),
                    "**Bold** and *it*")
    },
    test("should write headings with hashes and leave unsafe links as their text") {
        expectEqual(markdownText(fromHTML: "<h2>Plan</h2><p><a href=\"javascript:x()\">run</a></p>"), "## Plan\n\nrun")
    },
    test("should keep a table row on one line when its cells hold paragraphs, in Markdown and in plain text") {
        let html = "<table><tr><td><p>one</p><p>two</p></td><td>three</td></tr></table>"
        expectEqual(markdownText(fromHTML: html), "| one two | three |\n| --- | --- |")
        expectEqual(plainText(fromHTML: html, bullets: .dashes), "one two\tthree")
    },
    test("should give a code editor or terminal Markdown, but the plain text shortcut no markers") {
        let v = pasteVersions(copyOf(chatReply, plain: "Done."), sourceBundle: "com.microsoft.VSCode")!
        let md = v.representations(.markdown, target: .code)
        expectEqual(md.map(\.type), [PasteType.plain])
        expectEqual(String(data: md[0].data, encoding: .utf8), chatReplyMarkdown)
        let plain = String(data: v.representations(.plain, target: .code)[0].data, encoding: .utf8)!
        expect(!plain.contains("**") && !plain.contains("| ---"), plain)
    },
    test("should paste a code editor's own copy as copied when Markdown would add nothing") {
        let reps = copyOf(editorCode, plain: "if (a < b) {\n    run();\n}", extra: "org.chromium.source-url")
        let v = pasteVersions(reps, sourceBundle: "com.microsoft.VSCode")!
        expectEqual(v.representations(.markdown, target: .code).map(\.type), reps.map(\.type))
    },
    test("should paste a chat panel copy back into VS Code as Markdown and leave an editor copy untouched there") {
        let b = Board()
        b.copy(copyOf(chatReply, plain: "Done."), from: "com.microsoft.VSCode")
        b.press(into: "com.microsoft.VSCode")
        expectEqual(b.string(PasteType.plain), chatReplyMarkdown)
        let count = b.copy(copyOf(editorCode, plain: "if (a < b) {\n    run();\n}", extra: "org.chromium.source-url"), from: "com.microsoft.VSCode")
        b.press(into: "com.microsoft.VSCode")
        expectEqual(b.pb.changeCount, count, "the editor's copy, private types included, is not rewritten")
    },
]
