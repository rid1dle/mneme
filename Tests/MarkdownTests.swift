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

/// What VS Code's chat panel puts on the clipboard for a copied command shown as inline code.
private let copiedCommand = "<meta charset='utf-8'><span style=\"color: rgb(230, 219, 116); font-family: Menlo, monospace; background-color: rgb(40, 41, 54);\">open ~/work/noema/build/NoemaSpike.app</span>"

let terminalPasteTests: [TestCase] = [
    test("should not wrap a copied command in backticks, but keep inline code beside other text") {
        expect(markdownText(fromHTML: copiedCommand) == nil, markdownText(fromHTML: copiedCommand) ?? "")
        expectEqual(markdownText(fromHTML: "<p>Run <code>ls -la</code> now</p>"), "Run `ls -la` now")
    },
    test("should give a terminal text with no bullets, numbers, Markdown or indents, and code shifted left as a whole") {
        let html = "<p><strong>Steps</strong></p><ol><li>Build <code>app</code><ul><li>inner</li></ul></li><li>Run</li></ol><pre><code>    if a:\n        go()</code></pre>"
        expectEqual(plainText(fromHTML: cleanHTML(html), bullets: .bare), "Steps\n\nBuild app\ninner\nRun\n\nif a:\n    go()")
    },
    test("should take off the indent all lines share and keep the rest") {
        expectEqual(dedented("  open ~/x"), "open ~/x")
        expectEqual(dedented("    a\n      b\n\n    c"), "a\n  b\n\nc")
        expectEqual(dedented("a\n  b"), "a\n  b")
        expectEqual(dedented(""), "")
    },
    test("should prepare a flush version of indented plain text for terminals and leave other plain text alone") {
        let reps = [Representation(type: PasteType.plain, data: Data("  cd ~/x\n  make".utf8))]
        let v = pasteVersions(reps, sourceBundle: "com.apple.Terminal")!
        expectEqual(String(data: v.representations(.plain, target: .terminal)[0].data, encoding: .utf8), "cd ~/x\nmake")
        expectEqual(v.representations(.clean, target: .rich).map(\.type), [PasteType.plain], "other apps get it as copied")
        expect(pasteVersions([Representation(type: PasteType.plain, data: Data("cd ~/x".utf8))], sourceBundle: "com.apple.Terminal") == nil)
    },
    test("should treat terminal apps and a code editor's built-in terminal as terminals, and its editor as a code editor") {
        let none = PasteLearning()
        func v(_ p: PastePlace) -> PasteVersion { PasteRules.version(for: p, learned: none) }
        expectEqual(v(PastePlace(sourceBundle: "a", targetBundle: "com.apple.Terminal")), .plain)
        expectEqual(v(PastePlace(sourceBundle: "a", targetBundle: "com.mitchellh.ghostty")), .plain)
        expectEqual(v(PastePlace(sourceBundle: "a", targetBundle: "com.microsoft.VSCode")), .markdown)
        let term = PastePlace(sourceBundle: "com.microsoft.VSCode", targetBundle: "com.microsoft.VSCode", inTerminal: true)
        expectEqual(term.target, .terminal)
        expectEqual(v(term), .plain, "a copy from VS Code into its own terminal is not sent back as copied")
        expect(term.learningKey.hasSuffix("|terminal"), "the terminal learns apart from the editor")
        expectEqual(v(PastePlace(sourceBundle: "com.apple.Terminal", targetBundle: "com.apple.Terminal")), .plain)
    },
    test("should paste a copied command into a terminal without backticks and leave it as copied in the editor") {
        let b = Board()
        let count = b.copy(copyOf(copiedCommand, plain: "open ~/work/noema/build/NoemaSpike.app"), from: "com.microsoft.VSCode")
        b.press(into: "com.microsoft.VSCode")
        expectEqual(b.pb.changeCount, count, "the editor gets it as copied")
        b.press(into: "com.apple.Terminal")
        expectEqual(b.string(PasteType.plain), "open ~/work/noema/build/NoemaSpike.app")
    },
    test("should paste a chat reply into a terminal as plain lines") {
        let b = Board()
        b.copy(copyOf(chatReply, plain: "Done."), from: "com.microsoft.VSCode")
        b.press(into: "com.googlecode.iterm2")
        let t = b.string(PasteType.plain) ?? ""
        expect(!t.contains("**") && !t.contains("`") && !t.contains("| ---") && !t.contains("1. "), t)
        expect(t.contains("\nFixed: the mapping finding.\ninner\n"), t)
    },
    test("should paste indented text copied in a terminal back into it flush") {
        let b = Board()
        b.copy([Representation(type: PasteType.plain, data: Data("  open ~/x\n  --fast".utf8))], from: "com.apple.Terminal")
        b.press(into: "com.apple.Terminal")
        expectEqual(b.string(PasteType.plain), "open ~/x\n--fast")
    },
]
