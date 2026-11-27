import Foundation

// Formatting work on copied text, without AppKit: an HTML cleaner that keeps structure and drops looks, plain text
// rebuilt from HTML with its bullets, and Markdown-looking plain text turned into HTML.

// MARK: HTML tokens

enum HTMLToken: Equatable {
    case text(String)
    case start(String, [String: String], selfClosing: Bool)
    case end(String)
}

/// A forgiving HTML scanner for clipboard fragments: comments, doctypes and the content of script, style, head and
/// title are skipped; tag and attribute names come back lowercased; text keeps its entities.
func htmlTokens(_ html: String) -> [HTMLToken] {
    let b = Array(html.utf8)
    let n = b.count
    var out: [HTMLToken] = []
    var i = 0
    var textStart = 0
    func flushText(_ to: Int) { if to > textStart { out.append(.text(String(decoding: b[textStart..<to], as: UTF8.self))) } }
    func isNameByte(_ c: UInt8) -> Bool { c.isASCIIAlnum || c == UInt8(ascii: "-") || c == UInt8(ascii: ":") || c == UInt8(ascii: "_") }
    func find(_ pattern: [UInt8], from: Int) -> Int? {
        guard pattern.count <= n else { return nil }
        var j = from
        while j + pattern.count <= n {
            if b[j] == pattern[0] {
                var k = 1
                while k < pattern.count, b[j + k].lower == pattern[k] { k += 1 }
                if k == pattern.count { return j }
            }
            j += 1
        }
        return nil
    }
    while i < n {
        guard b[i] == UInt8(ascii: "<"), i + 1 < n else { i += 1; continue }
        let c = b[i + 1]
        if c == UInt8(ascii: "!") || c == UInt8(ascii: "?") {
            flushText(i)
            if i + 3 < n, b[i + 2] == UInt8(ascii: "-"), b[i + 3] == UInt8(ascii: "-") {
                i = (find(Array("-->".utf8), from: i + 4).map { $0 + 3 }) ?? n
            } else {
                i = (find([UInt8(ascii: ">")], from: i + 2).map { $0 + 1 }) ?? n
            }
            textStart = i
            continue
        }
        let closing = c == UInt8(ascii: "/")
        var j = i + (closing ? 2 : 1)
        guard j < n, b[j].isASCIILetter else { i += 1; continue }
        flushText(i)
        let nameStart = j
        while j < n, isNameByte(b[j]) { j += 1 }
        let name = String(decoding: b[nameStart..<j], as: UTF8.self).lowercased()
        var attrs: [String: String] = [:]
        var selfClosing = false
        while j < n, b[j] != UInt8(ascii: ">") {
            if b[j] == UInt8(ascii: "/") { selfClosing = true; j += 1; continue }
            if b[j].isSpace { j += 1; continue }
            let aStart = j
            while j < n, !b[j].isSpace, b[j] != UInt8(ascii: "="), b[j] != UInt8(ascii: ">"), b[j] != UInt8(ascii: "/") { j += 1 }
            let aName = String(decoding: b[aStart..<j], as: UTF8.self).lowercased()
            while j < n, b[j].isSpace { j += 1 }
            var value = ""
            if j < n, b[j] == UInt8(ascii: "=") {
                j += 1
                while j < n, b[j].isSpace { j += 1 }
                if j < n, b[j] == UInt8(ascii: "\"") || b[j] == UInt8(ascii: "'") {
                    let q = b[j]
                    let vStart = j + 1
                    j = vStart
                    while j < n, b[j] != q { j += 1 }
                    value = String(decoding: b[vStart..<min(j, n)], as: UTF8.self)
                    j += 1
                } else {
                    let vStart = j
                    while j < n, !b[j].isSpace, b[j] != UInt8(ascii: ">") { j += 1 }
                    value = String(decoding: b[vStart..<j], as: UTF8.self)
                }
            }
            if !aName.isEmpty { attrs[aName] = decodeEntities(value) }
            selfClosing = false
        }
        i = min(j + 1, n)
        if closing {
            out.append(.end(name))
        } else {
            out.append(.start(name, attrs, selfClosing: selfClosing))
            if ["script", "style", "head", "title", "xml"].contains(name), !selfClosing {
                let endTag = Array("</\(name)".utf8)
                if let e = find(endTag, from: i) {
                    i = (find([UInt8(ascii: ">")], from: e).map { $0 + 1 }) ?? n
                } else { i = n }
                out.removeLast()
            }
        }
        textStart = i
    }
    flushText(n)
    return out
}

private extension UInt8 {
    var isASCIILetter: Bool { (self | 0x20) >= 0x61 && (self | 0x20) <= 0x7a }
    var isASCIIAlnum: Bool { isASCIILetter || (self >= 0x30 && self <= 0x39) }
    var isSpace: Bool { self == 0x20 || self == 0x09 || self == 0x0a || self == 0x0d || self == 0x0c }
    var lower: UInt8 { isASCIILetter ? self | 0x20 : self }
}

func escapeHTML(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.append(ch)
        }
    }
    return out
}

/// CSS declarations of a style attribute, names lowercased.
func cssDeclarations(_ style: String?) -> [String: String] {
    guard let style else { return [:] }
    var out: [String: String] = [:]
    for part in style.split(separator: ";") {
        guard let colon = part.firstIndex(of: ":") else { continue }
        let k = part[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let v = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
        if !k.isEmpty { out[k] = v }
    }
    return out
}

private let monospaceFonts = ["mono", "menlo", "monaco", "consolas", "courier", "fira code", "source code", "hack", "inconsolata"]

private func isMonospace(_ css: [String: String]) -> Bool {
    guard let f = css["font-family"] else { return false }
    return monospaceFonts.contains { f.contains($0) }
}

private func isBold(_ css: [String: String]) -> Bool? {
    guard let w = css["font-weight"] else { return nil }
    if w == "bold" || w == "bolder" { return true }
    if let n = Int(w) { return n >= 600 }
    return w == "normal" || w == "lighter" ? false : nil
}

// MARK: clean

private let keptTags: Set<String> = [
    "p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "code", "strong", "em",
    "u", "s", "sub", "sup", "a", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "hr", "img",
]
private let renamedTags = ["b": "strong", "i": "em", "strike": "s", "del": "s", "ins": "u", "tt": "code", "kbd": "code", "samp": "code"]
private let keptAttributes: [String: Set<String>] = [
    "a": ["href"], "img": ["src", "alt", "width", "height"], "ol": ["start"], "td": ["colspan", "rowspan"], "th": ["colspan", "rowspan"],
]
private let voidTags: Set<String> = ["br", "hr", "img", "meta", "link", "input", "col", "wbr"]

/// The copy's structure without its looks, the way Slack takes a paste: paragraphs, headings, lists (nested and
/// numbered), bold, italic, underline, strikethrough, code, code blocks, links, quotes, tables and images stay;
/// colours, backgrounds, fonts, sizes and spacing go. Bold and italic set by style (Google Docs, Word) become tags;
/// a monospace block that keeps its spaces (a code editor's copy) becomes a code block.
public func cleanHTML(_ html: String) -> String {
    var out = ""
    out.reserveCapacity(html.utf8.count / 3)
    // For every open source element: the tags written for it, closed in reverse at its end.
    var open: [(name: String, wrote: [String])] = []
    // The open element that started a code block; inside it only line breaks are kept.
    var codeOwner: Int?
    var codeLines = 0
    func write(_ tag: String, _ attrs: [String: String] = [:]) {
        out += "<\(tag)"
        for (k, v) in attrs.sorted(by: { $0.key < $1.key }) { out += " \(k)=\"\(escapeHTML(v))\"" }
        out += ">"
    }
    for token in htmlTokens(html) {
        switch token {
        case .text(let t):
            out += t
        case .start(let raw, let attrs, let selfClosing):
            let opens = !voidTags.contains(raw) && !selfClosing
            if codeOwner != nil {
                if raw == "br" { out += "\n" } else if raw == "div" || raw == "p" { if codeLines > 0 { out += "\n" }; codeLines += 1 }
                if opens { open.append((raw, [])) }
                continue
            }
            let css = cssDeclarations(attrs["style"])
            let name = renamedTags[raw] ?? raw
            var wrote: [String] = []
            let codeBlock = name == "pre" || ((name == "div" || name == "p") && css["white-space"]?.hasPrefix("pre") == true && isMonospace(css))
            if codeBlock {
                write("pre")
                wrote = ["pre"]
                codeOwner = open.count
                codeLines = 0
            } else if raw == "b", isBold(css) == false {
                // Google Docs wraps a whole copy in <b style="font-weight:normal">.
            } else if keptTags.contains(name) {
                var kept: [String: String] = [:]
                for a in keptAttributes[name] ?? [] { if let v = attrs[a] { kept[a] = v } }
                if name == "a", let href = kept["href"], href.lowercased().hasPrefix("javascript:") { kept["href"] = nil }
                write(name, kept)
                if !voidTags.contains(name) { wrote.append(name) }
            }
            if !codeBlock, !["code", "h1", "h2", "h3", "h4", "h5", "h6", "th"].contains(name) {
                if isBold(css) == true, name != "strong" { write("strong"); wrote.append("strong") }
                if css["font-style"] == "italic", name != "em" { write("em"); wrote.append("em") }
                let deco = (css["text-decoration"] ?? "") + " " + (css["text-decoration-line"] ?? "")
                if deco.contains("underline"), name != "u", name != "a" { write("u"); wrote.append("u") }
                if deco.contains("line-through"), name != "s" { write("s"); wrote.append("s") }
                if isMonospace(css), !["div", "p", "li", "td", "th", "ul", "ol", "table"].contains(name) { write("code"); wrote.append("code") }
            }
            if opens { open.append((raw, wrote)) } else { for tag in wrote.reversed() where !voidTags.contains(tag) { out += "</\(tag)>" } }
        case .end(let raw):
            guard let at = open.lastIndex(where: { $0.name == raw }) else { continue }
            for entry in open[at...].reversed() { for tag in entry.wrote.reversed() { out += "</\(tag)>" } }
            if let o = codeOwner, o >= at { codeOwner = nil }
            open.removeSubrange(at...)
        }
    }
    for entry in open.reversed() { for tag in entry.wrote.reversed() { out += "</\(tag)>" } }
    return out
}

// MARK: plain text from HTML

public enum BulletStyle: Sendable {
    case dots, dashes
    /// Markdown: `-` bullets, `**bold**`, `*italic*`, `` `code` ``, links, `#` headings, pipe tables and fenced code.
    case markdown
}

/// Plain text that keeps what the HTML's structure said: bullets and indents for lists, numbers for numbered lists,
/// a blank line between paragraphs, tabs between table cells (so a table still lands in cells), code blocks as they
/// are. Entities are decoded and the source's line wrapping collapsed.
public func plainText(fromHTML html: String, bullets: BulletStyle = .dots) -> String {
    renderText(html, bullets).text
}

/// Markdown for a code editor, a terminal or an AI chat box, from HTML that has something only Markdown can carry
/// (a list, heading, table, bold, italic, inline code or link). Nil for anything else, such as a code editor's own
/// copy, which is pasted as it was copied.
public func markdownText(fromHTML html: String) -> String? {
    let r = renderText(cleanHTML(html), .markdown)
    return r.marked ? r.text : nil
}

private let inlineMarkers = ["strong": "**", "em": "*", "s": "~~", "code": "`"]

private func renderText(_ html: String, _ bullets: BulletStyle) -> (text: String, marked: Bool) {
    let md = bullets == .markdown
    var lines: [String] = []
    var line = ""
    var lists: [(ordered: Bool, next: Int, width: Int)] = []
    var pre = 0
    var pendingBlank = false
    var cellInRow = 0
    var inCell = false
    var tableRows = 0
    var pendingSpace = false
    // Markdown only: opening markers held until the text they wrap arrives, so "<strong> x</strong>" is " **x**".
    var pendingOpen = ""
    var links: [String] = []
    var marked = false

    func endLine() {
        let trimmed = pre > 0 ? line : String(line.reversed().drop(while: { $0 == " " }).reversed())
        if !trimmed.isEmpty || pre > 0 { lines.append(trimmed) }
        line = ""
        pendingSpace = false
        pendingOpen = ""
    }
    func block() {
        if !line.isEmpty { endLine() }
        if pendingBlank, let last = lines.last, !last.isEmpty, lists.isEmpty { lines.append("") }
        pendingBlank = false
    }
    func bullet(depth: Int) -> String {
        switch bullets {
        case .dots: return ["•", "◦", "▪"][min(depth, 2)]
        case .dashes, .markdown: return "-"
        }
    }
    func append(_ s: String) {
        if pendingSpace, !line.isEmpty, line.last != " ", line.last != "\t" { line += " " }
        pendingSpace = false
        line += pendingOpen + s
        pendingOpen = ""
    }
    func close(_ marker: String) {
        if pendingOpen.hasSuffix(marker) { pendingOpen.removeLast(marker.count) } else { line += marker; marked = true }
    }

    for token in htmlTokens(html) {
        switch token {
        case .text(let raw):
            var t = decodeEntities(raw)
            if pre > 0 {
                let parts = t.split(separator: "\n", omittingEmptySubsequences: false)
                for (k, p) in parts.enumerated() {
                    if k > 0 { lines.append(line); line = "" }
                    line += p
                }
                continue
            }
            if md, inCell { t = t.replacingOccurrences(of: "|", with: "\\|") }
            var words = t.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" || $0 == "\u{a0}" })
            if words.isEmpty { if !t.isEmpty { pendingSpace = true }; continue }
            if let f = t.first, f == " " || f == "\n" || f == "\t" || f == "\u{a0}" { pendingSpace = true }
            let first = String(words.removeFirst())
            append(first)
            for w in words { line += " " + w }
            if let l = t.last, l == " " || l == "\n" || l == "\t" || l == "\u{a0}" { pendingSpace = true }
        case .start(let name, let attrs, _):
            if md, pre == 0, let m = inlineMarkers[name] { pendingOpen += m; continue }
            if md, pre == 0, name == "a" {
                let href = attrs["href"] ?? ""
                let linkable = ["http", "https", "mailto"].contains(URL(string: href)?.scheme?.lowercased() ?? "")
                links.append(linkable ? href : "")
                if linkable { pendingOpen += "[" }
                continue
            }
            if inCell, pre == 0, ["br", "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "ul", "ol", "li"].contains(name) {
                pendingSpace = true
                continue
            }
            switch name {
            case "br": if pre > 0 { lines.append(line); line = "" } else { endLine() }
            case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "table", "hr":
                if pre > 0 { if !line.isEmpty { lines.append(line); line = "" }; continue }
                block()
                if name == "table" { tableRows = 0 }
                guard md else { continue }
                if name == "hr" { lines.append("---"); marked = true }
                if name.count == 2, name.first == "h", let n = Int(name.dropFirst()) {
                    line = String(repeating: "#", count: n) + " "
                    marked = true
                }
            case "pre":
                block()
                if md, pre == 0 { lines.append("```") }
                pre += 1
            case "ul", "ol":
                if pre > 0 { continue }
                if lists.isEmpty { block() } else if !line.isEmpty { endLine() }
                lists.append((name == "ol", Int(attrs["start"] ?? "") ?? 1, 0))
            case "li":
                if !line.isEmpty { endLine() }
                let depth = max(lists.count - 1, 0)
                let indent = md ? String(repeating: " ", count: lists.dropLast().reduce(0) { $0 + $1.width })
                                : String(repeating: bullets == .dots ? "    " : "  ", count: depth)
                if var top = lists.popLast() {
                    let marker = top.ordered ? "\(top.next). " : bullet(depth: depth) + " "
                    line = indent + marker
                    top.next += 1
                    top.width = marker.count
                    lists.append(top)
                } else {
                    line = bullet(depth: 0) + " "
                }
                if md { marked = true }
            case "tr":
                if !line.isEmpty { endLine() }
                cellInRow = 0
            case "td", "th":
                if md { line += cellInRow == 0 ? "| " : " | " } else if cellInRow > 0 { line += "\t" }
                cellInRow += 1
                inCell = true
                pendingSpace = false
            default: break
            }
        case .end(let name):
            if md, pre == 0, let m = inlineMarkers[name] { close(m); continue }
            if md, pre == 0, name == "a" {
                guard let href = links.popLast(), !href.isEmpty else { continue }
                if pendingOpen.hasSuffix("[") { pendingOpen.removeLast(); continue }
                if let open = line.range(of: "[", options: .backwards), line[open.upperBound...] == href {
                    line.remove(at: open.lowerBound)
                } else {
                    line += "](\(href))"
                }
                marked = true
                continue
            }
            if inCell, !["td", "th", "tr", "table"].contains(name) {
                if pre == 0, ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "ul", "ol", "li"].contains(name) { pendingSpace = true }
                continue
            }
            switch name {
            case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "table", "hr":
                if pre > 0 { continue }
                if !line.isEmpty { endLine() }
                pendingBlank = name != "div"
            case "pre":
                if pre > 0 {
                    pre -= 1
                    if pre == 0 {
                        if !line.isEmpty { lines.append(line) }
                        line = ""
                        if md { lines.append("```") }
                        pendingBlank = true
                    }
                }
            case "ul", "ol":
                if pre > 0 { continue }
                if !line.isEmpty { endLine() }
                _ = lists.popLast()
                if lists.isEmpty { pendingBlank = true }
            case "td", "th":
                inCell = false
            case "li", "tr":
                if name == "tr", md, cellInRow > 0 {
                    line += " |"
                    endLine()
                    if tableRows == 0 { lines.append("|" + String(repeating: " --- |", count: cellInRow)) }
                    tableRows += 1
                    marked = true
                    inCell = false
                    continue
                }
                inCell = false
                if !line.isEmpty { endLine() }
            default: break
            }
        }
    }
    if !line.isEmpty { endLine() }
    while lines.last?.isEmpty == true { lines.removeLast() }
    while lines.first?.isEmpty == true { lines.removeFirst() }
    return (lines.joined(separator: "\n"), marked)
}

/// True when the HTML has a list, the one thing a source's own plain text usually loses.
public func htmlHasList(_ html: String) -> Bool {
    let lower = html.lowercased()
    return lower.contains("<li") && (lower.contains("<ul") || lower.contains("<ol"))
}

// MARK: Markdown

private let listMarker = try! NSRegularExpression(pattern: #"^(\s*)([-*+•◦▪]|\d{1,3}[.)])\s+(.*)$"#)
private let headingMarker = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*)$"#)

/// Plain text that was written as Markdown (or a terminal's rendering of it): lists, headings, fenced code, quotes,
/// or bold and inline code next to a list. A single line or ordinary prose is not.
public func looksLikeMarkdown(_ text: String) -> Bool {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count >= 2 else { return false }
    var markers = 0
    var yamlItems = 0
    var fence = false
    for l in lines {
        let s = String(l)
        let r = NSRange(s.startIndex..., in: s)
        if s.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fence = true }
        if let m = listMarker.firstMatch(in: s, range: r) {
            markers += 1
            if let body = Range(m.range(at: 3), in: s), s[body].range(of: #"^[\w.-]+:(\s|$)"#, options: .regularExpression) != nil { yamlItems += 1 }
        } else if headingMarker.firstMatch(in: s, range: r) != nil || s.hasPrefix("> ") {
            markers += 1
        }
    }
    // "- name: web" lines are YAML (or similar config), not a list to format.
    if yamlItems * 2 > markers { return fence }
    let inline = text.contains("**") || text.range(of: #"`[^`\n]+`"#, options: .regularExpression) != nil
        || text.range(of: #"\[[^\]\n]+\]\(https?://[^)\s]+\)"#, options: .regularExpression) != nil
    return fence || markers >= 2 || (markers == 1 && inline)
}

/// Markdown to HTML for pasting into rich editors: headings, nested and numbered lists, fenced code, quotes,
/// paragraphs (lines inside one kept as line breaks), and inline bold, italic, code and links.
public func markdownToHTML(_ text: String) -> String {
    var out = ""
    var paragraph: [String] = []
    var lists: [(indent: Int, ordered: Bool)] = []
    var inCode = false
    var code: [String] = []

    func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        out += "<p>" + paragraph.map(inlineMarkdown).joined(separator: "<br>") + "</p>"
        paragraph = []
    }
    func closeLists(to indent: Int) {
        while let top = lists.last, top.indent > indent || (indent < 0) {
            out += "</li>" + (top.ordered ? "</ol>" : "</ul>")
            lists.removeLast()
        }
    }

    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let l = String(raw)
        if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            if inCode {
                out += "<pre><code>" + escapeHTML(code.joined(separator: "\n")) + "</code></pre>"
                code = []
                inCode = false
            } else {
                flushParagraph(); closeLists(to: -1)
                inCode = true
            }
            continue
        }
        if inCode { code.append(l); continue }
        let r = NSRange(l.startIndex..., in: l)
        if let m = listMarker.firstMatch(in: l, range: r) {
            flushParagraph()
            let indent = Range(m.range(at: 1), in: l).map { l[$0].replacingOccurrences(of: "\t", with: "    ").count } ?? 0
            let marker = Range(m.range(at: 2), in: l).map { String(l[$0]) } ?? "-"
            let ordered = marker.first?.isNumber == true
            let body = Range(m.range(at: 3), in: l).map { String(l[$0]) } ?? ""
            closeLists(to: indent)
            if let top = lists.last, top.indent == indent, top.ordered == ordered {
                out += "</li><li>"
            } else {
                if let top = lists.last, top.indent == indent {
                    out += "</li>" + (top.ordered ? "</ol>" : "</ul>")
                    lists.removeLast()
                }
                let start = ordered ? Int(marker.dropLast()) ?? 1 : 1
                out += ordered ? (start == 1 ? "<ol><li>" : "<ol start=\"\(start)\"><li>") : "<ul><li>"
                lists.append((indent, ordered))
            }
            out += inlineMarkdown(body)
            continue
        }
        if let m = headingMarker.firstMatch(in: l, range: r) {
            flushParagraph(); closeLists(to: -1)
            let level = m.range(at: 1).length
            let body = Range(m.range(at: 2), in: l).map { String(l[$0]) } ?? ""
            out += "<h\(level)>" + inlineMarkdown(body) + "</h\(level)>"
            continue
        }
        let trimmed = l.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { flushParagraph(); closeLists(to: -1); continue }
        if trimmed.hasPrefix(">") {
            flushParagraph(); closeLists(to: -1)
            out += "<blockquote>" + inlineMarkdown(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)) + "</blockquote>"
            continue
        }
        if !lists.isEmpty, l.first == " " {
            // A wrapped continuation of the list item above.
            out += " " + inlineMarkdown(trimmed)
            continue
        }
        closeLists(to: -1)
        paragraph.append(trimmed)
    }
    if inCode { out += "<pre><code>" + escapeHTML(code.joined(separator: "\n")) + "</code></pre>" }
    flushParagraph()
    closeLists(to: -1)
    return out
}

private let inlineRules: [(NSRegularExpression, String)] = [
    (try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((https?://[^)\s]+)\)"#), "<a href=\"$2\">$1</a>"),
    (try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#), "<strong>$1</strong>"),
    (try! NSRegularExpression(pattern: #"__([^_\n]+)__"#), "<strong>$1</strong>"),
    (try! NSRegularExpression(pattern: #"(?<![*\w])\*([^*\n]+)\*(?![*\w])"#), "<em>$1</em>"),
    (try! NSRegularExpression(pattern: #"(?<![_\w])_([^_\n]+)_(?![_\w])"#), "<em>$1</em>"),
    (try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#), "<s>$1</s>"),
]

/// Inline Markdown in one line. Code spans are cut out first so nothing inside them is read as Markdown.
func inlineMarkdown(_ s: String) -> String {
    var pieces: [(code: Bool, text: String)] = []
    var rest = Substring(s)
    while let open = rest.firstIndex(of: "`"), let close = rest[rest.index(after: open)...].firstIndex(of: "`") {
        pieces.append((false, String(rest[..<open])))
        pieces.append((true, String(rest[rest.index(after: open)..<close])))
        rest = rest[rest.index(after: close)...]
    }
    pieces.append((false, String(rest)))
    return pieces.map { p in
        if p.code { return "<code>" + escapeHTML(p.text) + "</code>" }
        var t = escapeHTML(p.text)
        for (re, template) in inlineRules {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: template)
        }
        return t
    }.joined()
}

/// Plain text as HTML that pastes as plain text: escaped, lines kept, no styling.
public func htmlFromPlain(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { escapeHTML(String($0)) }.joined(separator: "<br>")
}
