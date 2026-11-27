import Foundation

/// The page title (og:title, twitter:title, then <title>) and preview image (og:image, twitter:image) of an HTML
/// page head. Only http(s) images are returned, resolved against the page address.
public func parseLinkMeta(html: String, base: URL) -> (title: String?, image: URL?) {
    let head: Substring
    if let end = html.range(of: "</head>", options: .caseInsensitive) { head = html[..<end.lowerBound] } else { head = html[...] }
    let text = String(head)
    var meta: [String: String] = [:]
    for tag in matches(#"<meta\b[^>]*>"#, in: text) {
        var attrs: [String: String] = [:]
        for m in groups(#"([a-zA-Z_:\-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>"']+))"#, in: tag) {
            let value = m[3] ?? m[4] ?? m[5] ?? ""
            attrs[m[1]!.lowercased()] = value
        }
        if let key = (attrs["property"] ?? attrs["name"])?.lowercased(), let content = attrs["content"], meta[key] == nil {
            meta[key] = content
        }
    }
    let pageTitle = groups(#"<title[^>]*>([\s\S]*?)</title>"#, in: text).first?[1]
    let title = [meta["og:title"], meta["twitter:title"], pageTitle].compactMap { $0 }.map(cleanText).first { !$0.isEmpty }
    let image = [meta["og:image"], meta["og:image:url"], meta["twitter:image"]].compactMap { $0 }
        .compactMap { URL(string: decodeEntities($0).trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL }
        .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    return (title, image)
}

private func cleanText(_ s: String) -> String {
    decodeEntities(s).split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

func decodeEntities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "\u{2014}", "ndash": "\u{2013}",
                 "hellip": "\u{2026}", "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}",
                 "ensp": " ", "emsp": " ", "thinsp": " ", "bull": "\u{2022}", "middot": "\u{00B7}", "rarr": "\u{2192}", "larr": "\u{2190}",
                 "times": "\u{00D7}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "deg": "\u{00B0}", "zwj": "", "zwnj": "", "shy": ""]
    var out = ""
    var i = s.startIndex
    while i < s.endIndex {
        if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
            let name = String(s[s.index(after: i)..<semi])
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") { replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init) }
            else if name.hasPrefix("#") { replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map(String.init) }
            else { replacement = named[name.lowercased()] }
            if let replacement { out += replacement; i = s.index(after: semi); continue }
        }
        out.append(s[i])
        i = s.index(after: i)
    }
    return out
}

private func matches(_ pattern: String, in s: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let ns = s as NSString
    return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
}

private func groups(_ pattern: String, in s: String) -> [[Int: String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let ns = s as NSString
    return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
        var out: [Int: String] = [:]
        for g in 0..<m.numberOfRanges where m.range(at: g).location != NSNotFound { out[g] = ns.substring(with: m.range(at: g)) }
        return out
    }
}

/// Previews are fetched only for public web pages: never loopback, private or link-local addresses, `.local` or
/// single-label hosts (that would reach the user's own servers, and macOS would ask for Local Network access), and
/// never links that look single-use (login, verify, reset, tokens), which a fetch could spend.
public func shouldFetchPreview(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          var host = url.host?.lowercased(), !host.isEmpty else { return false }
    host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
        || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") || !host.contains(".") && !host.contains(":") { return false }
    if host.contains(":") { return false }   // IPv6 literal: keep it simple and skip
    let parts = host.split(separator: ".").compactMap { Int($0) }
    if parts.count == 4 {
        let (a, b) = (parts[0], parts[1])
        if a == 10 || a == 127 || a == 0 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 100 && (64...127).contains(b)) { return false }
    }
    let oneTime = ["token", "code", "otp", "sig", "signature", "auth", "key", "magic", "nonce", "ticket", "session", "password", "secret"]
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
    if query.contains(where: { name in oneTime.contains { name == $0 || name.hasSuffix("_" + $0) || name.hasPrefix($0 + "_") } }) { return false }
    let path = url.path.lowercased()
    if ["login", "signin", "sign-in", "verify", "verification", "confirm", "reset", "unsubscribe", "magic", "activate", "invite"]
        .contains(where: { path.contains($0) }) { return false }
    return true
}
