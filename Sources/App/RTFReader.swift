import AppKit

/// Clean HTML from a rich text copy (Word, Pages, TextEdit, Notes), in the same vocabulary as `cleanHTML`: paragraphs,
/// nested and numbered lists, bold, italic, underline, strikethrough, monospace as code, and links. Colours, fonts and
/// sizes are left behind. RTF is read without WebKit, so this is safe off the main thread.
func htmlFromRichText(_ data: Data, rtfd: Bool) -> String? {
    let type: NSAttributedString.DocumentType = rtfd ? .rtfd : .rtf
    guard let s = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil), s.length > 0 else { return nil }
    let text = s.string as NSString
    var out = ""
    var lists: [Bool] = []   // open lists, true when numbered

    func closeLists(to depth: Int) {
        while lists.count > depth { out += "</li>" + (lists.removeLast() ? "</ol>" : "</ul>") }
    }

    var start = 0
    while start < text.length {
        var end = 0, contentsEnd = 0
        text.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
        defer { start = end }
        var range = NSRange(location: start, length: contentsEnd - start)
        let style = s.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
        let textLists = style?.textLists ?? []
        if !textLists.isEmpty {
            // The marker is part of the text ("\t•\t" or "\t1.\t"): skip it.
            let para = text.substring(with: range)
            if let m = para.range(of: #"^\t?[^\t]{0,12}\t"#, options: .regularExpression) {
                let skip = (para[m.lowerBound..<m.upperBound] as Substring).utf16.count
                range = NSRange(location: range.location + skip, length: range.length - skip)
            }
        }
        let body = inlineHTML(s, range)
        if textLists.isEmpty {
            closeLists(to: 0)
            if !body.trimmingCharacters(in: .whitespaces).isEmpty { out += "<p>\(body)</p>" }
            continue
        }
        let depth = textLists.count
        let numbered = isNumbered(textLists[depth - 1].markerFormat)
        closeLists(to: depth)
        if lists.count == depth {
            if lists[depth - 1] == numbered {
                out += "</li><li>"
            } else {
                out += "</li>" + (lists.removeLast() ? "</ol>" : "</ul>")
                out += numbered ? "<ol><li>" : "<ul><li>"
                lists.append(numbered)
            }
        } else {
            while lists.count < depth {
                let n = lists.count == depth - 1 ? numbered : false
                out += n ? "<ol><li>" : "<ul><li>"
                lists.append(n)
            }
        }
        out += body
    }
    closeLists(to: 0)
    return out.isEmpty ? nil : out
}

private func isNumbered(_ f: NSTextList.MarkerFormat) -> Bool {
    [.decimal, .lowercaseAlpha, .uppercaseAlpha, .lowercaseRoman, .uppercaseRoman, .lowercaseLatin, .uppercaseLatin,
     .lowercaseHexadecimal, .uppercaseHexadecimal, .octal].contains(f)
}

/// One paragraph's runs as inline HTML.
private func inlineHTML(_ s: NSAttributedString, _ range: NSRange) -> String {
    var out = ""
    s.enumerateAttributes(in: range) { attrs, r, _ in
        var t = escapeHTML((s.string as NSString).substring(with: r)).replacingOccurrences(of: "\u{2028}", with: "<br>")
        guard !t.isEmpty else { return }
        let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        if traits.contains(.monoSpace) { t = "<code>\(t)</code>" }
        if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { t = "<s>\(t)</s>" }
        if (attrs[.underlineStyle] as? Int ?? 0) != 0, attrs[.link] == nil { t = "<u>\(t)</u>" }
        if traits.contains(.italic) { t = "<em>\(t)</em>" }
        if traits.contains(.bold) { t = "<strong>\(t)</strong>" }
        let link = (attrs[.link] as? URL)?.absoluteString ?? attrs[.link] as? String
        if let link, let scheme = URL(string: link)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            t = "<a href=\"\(escapeHTML(link))\">\(t)</a>"
        }
        out += t
    }
    return out
}
