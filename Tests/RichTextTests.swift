import Foundation

/// The shape of a copy from VS Code's chat panel: dark theme colours on every block, a nested list, bold labels,
/// inline code, and Chromium's spacer spans.
private let editorChatCopy = """
<meta charset='utf-8'><p style="white-space: pre-wrap; margin-top: 0px; color: rgb(248, 248, 242); font-family: -apple-system, system-ui; font-size: 13px; background-color: rgb(33, 34, 44);">The brief is ready.</p>\
<p style="white-space: pre-wrap; color: rgb(248, 248, 242); background-color: rgb(33, 34, 44);"><strong style="font-weight: 600; color: rgb(248, 248, 242);">The brief:</strong> <code style="font-family: Menlo; background-color: rgb(50, 50, 60);">brief.md</code>. In short:</p>\
<ul style="padding-left: 2em; color: rgb(248, 248, 242); background-color: rgb(33, 34, 44);"><li><strong>What happened:</strong><span> </span>both cases.</li>\
<li><strong>What to change:</strong><ul><li>clear the port;</li><li>check after <code>stop</code> &amp; restart.</li></ul></li></ul>\
<p style="color: rgb(248, 248, 242);">Not proven: how.</p>
"""

private let editorCodeCopy = """
<meta charset="utf-8"><div style="color: #d4d4d4;background-color: #1e1e1e;font-family: Menlo, Monaco, 'Courier New', monospace;font-size: 12px;line-height: 18px;white-space: pre;"><div><span style="color: #569cd6;">if</span> (a &lt; b) {</div><div>    <span style="color: #dcdcaa;">run</span>();</div><div>}</div></div>
"""

private let googleDocsCopy = """
<meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1"><p dir="ltr" style="line-height:1.38;"><span style="font-size:11pt;font-family:Arial;color:#000000;font-weight:700;">Bold</span><span style="font-size:11pt;font-family:Arial;color:#000000;font-weight:400;"> and </span><span style="font-style:italic;color:#ff0000;">red italic</span></p></b>
"""

private func has(_ s: String, _ part: String) -> Bool { s.contains(part) }

let richTextTests: [TestCase] = [
    test("should drop the editor theme's colours, background and fonts from a rich copy") {
        let c = cleanHTML(editorChatCopy)
        for gone in ["style=", "rgb(", "font-family", "background", "<meta", "<span"] { expect(!has(c, gone), "still has \(gone): \(c)") }
    },
    test("should keep paragraphs, bold labels, inline code and the nested list when cleaning") {
        let c = cleanHTML(editorChatCopy)
        expect(has(c, "<p>The brief is ready.</p>"), c)
        expect(has(c, "<strong>The brief:</strong> <code>brief.md</code>"), c)
        expect(has(c, "<ul><li><strong>What happened:</strong> both cases.</li>"), c)
        expect(has(c, "<li><strong>What to change:</strong><ul><li>clear the port;</li><li>check after <code>stop</code> &amp; restart.</li></ul></li></ul>"), c)
    },
    test("should turn a code editor's monospace block into a code block that keeps its lines and spaces") {
        let c = cleanHTML(editorCodeCopy)
        expectEqual(c.trimmingCharacters(in: .whitespacesAndNewlines), "<pre>if (a &lt; b) {\n    run();\n}</pre>")
    },
    test("should keep Google Docs bold and italic set by style, and not bold everything its wrapper claims") {
        let c = cleanHTML(googleDocsCopy)
        expect(has(c, "<strong>Bold</strong>"), c)
        expect(has(c, "<em>red italic</em>"), c)
        expect(!has(c, "<strong> and"), "normal-weight text stays normal: \(c)")
        expect(!has(c, "ff0000"), c)
    },
    test("should keep links, headings and tables but not scripts, styles or javascript links") {
        let c = cleanHTML("<style>p{color:red}</style><h2 class=x>Title</h2><a href=\"https://a.b/c\" style=\"color:blue\">link</a><a href=\"javascript:alert(1)\">x</a><script>alert(1)</script><table border=1><tr><td colspan=\"2\" style=\"background:#ff0\">cell</td></tr></table>")
        expectEqual(c, "<h2>Title</h2><a href=\"https://a.b/c\">link</a><a>x</a><table><tr><td colspan=\"2\">cell</td></tr></table>")
    },
    test("should close tags the source left open and ignore stray closing tags") {
        expectEqual(cleanHTML("<ul><li>one<li>two</div>"), "<ul><li>one<li>two</li></li></ul>")
    },
    test("should rebuild bullets, nesting and paragraphs in plain text from a rich copy") {
        let p = plainText(fromHTML: editorChatCopy)
        expectEqual(p, """
        The brief is ready.

        The brief: brief.md. In short:

        • What happened: both cases.
        • What to change:
            ◦ clear the port;
            ◦ check after stop & restart.

        Not proven: how.
        """)
    },
    test("should write Markdown-style dashes for code editors and terminals") {
        let p = plainText(fromHTML: "<ul><li>a<ul><li>b</li></ul></li></ul>", bullets: .dashes)
        expectEqual(p, "- a\n  - b")
    },
    test("should number numbered lists from their start") {
        expectEqual(plainText(fromHTML: "<ol start=\"3\"><li>c</li><li>d</li></ol>"), "3. c\n4. d")
    },
    test("should keep table cells apart with tabs so a table still lands in cells") {
        expectEqual(plainText(fromHTML: "<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>"), "A\tB\n1\t2")
    },
    test("should keep a code block's lines and spaces in plain text") {
        expectEqual(plainText(fromHTML: "<p>Run:</p><pre>a  b\n  c</pre><p>done</p>"), "Run:\n\na  b\n  c\n\ndone")
    },
    test("should decode entities and line breaks") {
        expectEqual(plainText(fromHTML: "x&nbsp;&lt;y&gt;&#8594;&#x41;<br>z"), "x <y>→A\nz")
    },
    test("should spot Markdown and leave ordinary text alone") {
        expect(looksLikeMarkdown("Notes:\n- one\n- two"))
        expect(looksLikeMarkdown("## Plan\nDo **this** first"))
        expect(looksLikeMarkdown("Run it:\n```\nls\n```"))
        expect(!looksLikeMarkdown("Hello there,\nsee you at 5."))
        expect(!looksLikeMarkdown("- just one line"))
        expect(!looksLikeMarkdown("let x = 1\nlet y = 2"))
        expect(!looksLikeMarkdown("services:\n  - name: web\n    image: nginx\n  - name: db"), "YAML is config, not a list")
    },
    test("should turn Markdown into HTML with nested lists, headings, code and inline styles") {
        let h = markdownToHTML("## Plan\nIntro with **bold** and `a*b*c`.\n- one\n  - inner\n- two [site](https://x.y)\n1. first\n2. second\n```\nlet a = 1 < 2\n```")
        expectEqual(h, "<h2>Plan</h2><p>Intro with <strong>bold</strong> and <code>a*b*c</code>.</p><ul><li>one<ul><li>inner</li></ul></li><li>two <a href=\"https://x.y\">site</a></li></ul><ol><li>first</li><li>second</li></ol><pre><code>let a = 1 &lt; 2</code></pre>")
    },
    test("should keep lines of one paragraph as line breaks and escape HTML in Markdown") {
        expectEqual(markdownToHTML("a <b>\nc\n\n- x"), "<p>a &lt;b&gt;<br>c</p><ul><li>x</li></ul>")
    },
]

private func reps(html: String? = nil, plain: String?, extra: [String: String] = [:]) -> [Representation] {
    var r: [Representation] = []
    if let html { r.append(Representation(type: PasteType.html, data: Data(html.utf8))) }
    if let plain { r.append(Representation(type: PasteType.plain, data: Data(plain.utf8))) }
    for (k, v) in extra { r.append(Representation(type: k, data: Data(v.utf8))) }
    return r
}

private func text(_ r: [Representation], _ type: String) -> String? {
    r.first { $0.type == type }.flatMap { String(data: $0.data, encoding: .utf8) }
}

let pasteFormatTests: [TestCase] = [
    test("should give spreadsheets the original, code editors and chats plain text, and mail or docs clean formatting") {
        let none = PasteLearning()
        func v(_ target: String, _ title: String? = nil) -> PasteVersion {
            PasteRules.version(for: PastePlace(sourceBundle: "com.microsoft.VSCode", targetBundle: target, windowTitle: title), learned: none)
        }
        expectEqual(v("com.microsoft.Excel"), .original)
        expectEqual(v("com.apple.iWork.Numbers"), .original)
        expectEqual(v("com.apple.Terminal"), .plain)
        expectEqual(v("com.mitchellh.ghostty"), .plain)
        expectEqual(v("net.whatsapp.WhatsApp"), .plain)
        expectEqual(v("com.apple.mail"), .clean)
        expectEqual(v("com.tinyspeck.slackmacgap"), .clean)
        expectEqual(v("app.zen-browser.zen", "Inbox (3) - me@x.com - Gmail"), .clean)
        expectEqual(v("com.google.Chrome", "Budget - Google Sheets"), .original)
        expectEqual(v("app.zen-browser.zen", "(2) WhatsApp"), .plain)
        expectEqual(v("com.unknown.app"), .clean)
    },
    test("should paste the original back into the app it was copied from") {
        let p = PastePlace(sourceBundle: "com.microsoft.VSCode", targetBundle: "com.microsoft.VSCode")
        expectEqual(PasteRules.version(for: p, learned: PasteLearning()), .original)
        expectEqual(pasteReason(p, learned: PasteLearning()), "same-app")
    },
    test("should tell sites apart by window title in a browser and not elsewhere") {
        expectEqual(PastePlace(sourceBundle: nil, targetBundle: "com.google.Chrome", windowTitle: "Q3 plan - Google Docs").site, "Google Docs")
        expectEqual(PastePlace(sourceBundle: nil, targetBundle: "com.google.Chrome", windowTitle: "Some page - Example Site").site, "Example Site")
        expect(PastePlace(sourceBundle: nil, targetBundle: "com.apple.mail", windowTitle: "Inbox - Gmail").site == nil)
    },
    test("should learn a place's version after the same choice twice in a row, and change it the same way") {
        var l = PasteLearning()
        let p = PastePlace(sourceBundle: "com.microsoft.VSCode", targetBundle: "com.google.Chrome", windowTitle: "Inbox - Gmail")
        l.record(.plain, key: p.learningKey)
        expectEqual(PasteRules.version(for: p, learned: l), .clean, "one choice is not a rule yet")
        l.record(.plain, key: p.learningKey, name: "Code to Gmail")
        expectEqual(PasteRules.version(for: p, learned: l), .plain)
        expectEqual(pasteReason(p, learned: l), "learned")
        l.record(.original, key: p.learningKey)
        expectEqual(PasteRules.version(for: p, learned: l), .clean, "a different choice undoes it")
        l.record(.original, key: p.learningKey)
        expectEqual(PasteRules.version(for: p, learned: l), .original)
        expectEqual(l.rules.map(\.name), ["Code to Gmail"])
        l.forget(p.learningKey)
        expectEqual(PasteRules.version(for: p, learned: l), .clean)
    },
    test("should learn per place, so a choice in Gmail does not change Slack") {
        var l = PasteLearning()
        let gmail = PastePlace(sourceBundle: "a", targetBundle: "com.google.Chrome", windowTitle: "Inbox - Gmail")
        let slack = PastePlace(sourceBundle: "a", targetBundle: "com.tinyspeck.slackmacgap")
        l.record(.plain, key: gmail.learningKey); l.record(.plain, key: gmail.learningKey)
        expectEqual(PasteRules.version(for: slack, learned: l), .clean)
    },
    test("should keep only the last few choices per place") {
        var l = PasteLearning()
        for _ in 0..<20 { l.record(.plain, key: "k") }
        expectEqual(l.choices["k"]?.count, 5)
    },
    test("should build clean and plain versions of a rich copy, keeping the original whole") {
        let r = reps(html: editorChatCopy, plain: "The brief is ready.\nWhat happened: both cases.", extra: ["vscode-editor-data": "{}"])
        guard let v = pasteVersions(r, sourceBundle: "com.microsoft.VSCode") else { expect(false, "no versions"); return }
        expectEqual(v.original, r)
        expect(text(v.clean, PasteType.html)?.contains("style=") == false)
        expectEqual(Set(v.clean.map(\.type)), [PasteType.html, PasteType.plain], "app-private types stay with the original only")
        expect(v.plainDots.contains("• What happened"), v.plainDots)
        expect(v.plainDashes.contains("- What happened"), v.plainDashes)
        expectEqual(text(v.representations(.plain, target: .code), PasteType.plain), v.plainDashes)
        expectEqual(v.representations(.plain, target: .plainChat).map(\.type), [PasteType.plain])
    },
    test("should keep the source's own plain text when its HTML has no list to rebuild") {
        let r = reps(html: editorCodeCopy, plain: "if (a < b) {\n    run();\n}")
        expectEqual(pasteVersions(r, sourceBundle: "com.microsoft.VSCode")?.plainDots, "if (a < b) {\n    run();\n}")
    },
    test("should add a rich version to Markdown-looking plain text and leave other plain text alone") {
        let md = pasteVersions(reps(plain: "Plan:\n- one\n- **two**"), sourceBundle: "com.apple.Terminal")
        expectEqual(md.flatMap { text($0.clean, PasteType.html) }, "<p>Plan:</p><ul><li>one</li><li><strong>two</strong></li></ul>")
        expectEqual(md?.plainDots, "Plan:\n- one\n- **two**")
        expect(pasteVersions(reps(plain: "just a sentence"), sourceBundle: nil) == nil)
    },
    test("should leave spreadsheet copies, files, images and several items alone") {
        expect(pasteVersions(reps(html: "<table></table>", plain: "a\tb"), sourceBundle: "com.microsoft.Excel") == nil)
        expect(pasteVersions(reps(html: "<p>x</p>", plain: "x", extra: [PasteType.fileURL: "file:///a"]), sourceBundle: nil) == nil)
        expect(pasteVersions(reps(html: "<p>x</p>", plain: "x", extra: [PasteType.png: "png"]), sourceBundle: nil) == nil)
        let two = [Representation(index: 0, type: PasteType.html, data: Data("<p>a</p>".utf8)), Representation(index: 1, type: PasteType.html, data: Data("<p>b</p>".utf8))]
        expect(pasteVersions(two, sourceBundle: nil) == nil)
    },
    test("should leave very large HTML alone") {
        let big = "<p>" + String(repeating: "x", count: maxFormattedHTMLBytes) + "</p>"
        expect(pasteVersions(reps(html: big, plain: "x"), sourceBundle: nil) == nil)
    },
    test("should log where a paste went and why, without its content") {
        let place = PastePlace(sourceBundle: "a", targetBundle: "com.google.Chrome", windowTitle: "Inbox - Gmail")
        let e = PasteLogEntry(time: Date(timeIntervalSince1970: 0), place: place, version: .clean, reason: "rule", via: "cmd-v", markdown: false)
        let json = String(data: try! JSONEncoder().encode(e), encoding: .utf8)!
        expect(json.contains("\"site\":\"Gmail\""), json)
        expect(json.contains("\"version\":\"clean\""), json)
    },
]
