import Foundation

/// What a link is, read from its address alone (no network, so it works for private pages and old links).
public struct LinkSummary: Equatable {
    public var site: String
    /// SF Symbol name for the kind; nil = show the site's first letter.
    public var symbol: String?
    /// Badge colour, #RRGGBB.
    public var color: String
    /// Where it lives: "owner/repo", a workspace, a team.
    public var context: String
    /// The big line: "#2479", "PLAT-142", a page name.
    public var headline: String
    /// "Pull request", "Issue", or the host for a plain page.
    public var kind: String
    /// A second line some addresses carry (a ticket's title in its slug).
    public var detail: String?

    public init(site: String, symbol: String? = nil, color: String, context: String, headline: String, kind: String, detail: String? = nil) {
        self.site = site; self.symbol = symbol; self.color = color; self.context = context
        self.headline = headline; self.kind = kind; self.detail = detail
    }
}

private let githubReserved: Set<String> = [
    "settings", "notifications", "explore", "marketplace", "pulls", "issues", "login", "logout", "join", "orgs",
    "sponsors", "topics", "trending", "new", "organizations", "codespaces", "features", "about", "pricing", "search",
]

/// GitHub addresses only (pull requests, issues, commits, files...); nil for anything else.
public func summarizeLink(_ url: URL) -> LinkSummary? {
    guard let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    guard parts.count >= 2, !githubReserved.contains(parts[0].lowercased()) else { return nil }
    let (owner, repo) = (parts[0], parts[1])
    let ctx = "\(owner)/\(repo)"
    func make(_ symbol: String, _ headline: String, _ kind: String, context: String? = nil) -> LinkSummary {
        LinkSummary(site: "GitHub", symbol: symbol, color: "#24292F", context: context ?? ctx, headline: headline, kind: kind)
    }
    guard parts.count >= 3 else { return make("book.closed", repo, "Repository", context: owner) }
    let rest = Array(parts.dropFirst(3))
    switch parts[2] {
    case "pull" where !rest.isEmpty: return make("arrow.triangle.pull", "#\(rest[0])", "Pull request")
    case "issues" where !rest.isEmpty: return make("smallcircle.filled.circle", "#\(rest[0])", "Issue")
    case "discussions" where !rest.isEmpty: return make("bubble.left.and.bubble.right", "#\(rest[0])", "Discussion")
    case "commit" where !rest.isEmpty: return make("circle.and.line.horizontal", String(rest[0].prefix(7)), "Commit")
    case "blob" where rest.count >= 2: return make("doc.text", rest.last!, "File on \(rest[0])")
    case "tree" where rest.count >= 2: return make("folder", rest.last!, "Folder on \(rest[0])")
    case "tree" where rest.count == 1: return make("arrow.triangle.branch", rest[0], "Branch")
    case "releases" where rest.count >= 2 && rest[0] == "tag": return make("tag", rest[1], "Release")
    case "actions" where rest.count >= 2 && rest[0] == "runs": return make("play.circle", "#\(rest[1])", "Actions run")
    case "compare" where !rest.isEmpty: return make("arrow.left.arrow.right", rest.joined(separator: "/"), "Comparison")
    case "pulls": return make("arrow.triangle.pull", repo, "Pull requests", context: owner)
    case "issues": return make("smallcircle.filled.circle", repo, "Issues", context: owner)
    case "actions": return make("play.circle", repo, "Actions", context: owner)
    default: return make("book.closed", repo, "Repository", context: owner)
    }
}

/// Any web link: a known site's address read in detail, a local server, or the site's name and a readable page
/// name. nil only for addresses that are not http(s).
public func describeLink(_ url: URL) -> LinkSummary? {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let rawHost = url.host?.lowercased(), !rawHost.isEmpty else { return nil }
    if let github = summarizeLink(url) { return github }
    let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
    let parts = url.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
    let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                           uniquingKeysWith: { a, _ in a })
    func at(_ i: Int) -> String? { parts.indices.contains(i) ? parts[i] : nil }
    func s(_ site: String, _ color: String, _ symbol: String?, context: String, headline: String, kind: String, detail: String? = nil) -> LinkSummary {
        LinkSummary(site: site, symbol: symbol, color: color, context: context, headline: headline, kind: kind, detail: detail)
    }
    let label = host.split(separator: ".").first.map(String.init) ?? host

    // Local servers (never fetched; see shouldFetchPreview).
    if !shouldFetchPreview(url), host == "localhost" || host.hasSuffix(".local") || host.allSatisfy({ $0.isNumber || $0 == "." }) {
        let port = url.port.map { ":\($0)" } ?? host
        return s("Local server", "#5B6573", "server.rack", context: host, headline: port, kind: url.path.isEmpty ? "/" : url.path)
    }

    switch true {
    case host == "gitlab.com" || host.hasPrefix("gitlab."):
        if let dash = parts.firstIndex(of: "-"), let kind = at(dash + 1), let n = at(dash + 2) {
            let project = parts[..<dash].joined(separator: "/")
            switch kind {
            case "merge_requests": return s("GitLab", "#FC6D26", "arrow.triangle.merge", context: project, headline: "!\(n)", kind: "Merge request")
            case "issues": return s("GitLab", "#FC6D26", "smallcircle.filled.circle", context: project, headline: "#\(n)", kind: "Issue")
            case "commit": return s("GitLab", "#FC6D26", "circle.and.line.horizontal", context: project, headline: String(n.prefix(8)), kind: "Commit")
            default: break
            }
        }
    case host.hasSuffix(".atlassian.net") || host.hasPrefix("jira."):
        let org = label
        if let i = parts.firstIndex(of: "browse"), let key = at(i + 1) {
            return s("Jira", "#0052CC", "checkmark.square", context: org, headline: key, kind: "Issue")
        }
        if parts.first == "wiki", let i = parts.firstIndex(of: "pages") {
            let title = at(i + 2).map { humanize($0.replacingOccurrences(of: "+", with: " ")) } ?? "Page"
            return s("Confluence", "#1868DB", "doc.richtext", context: at(2) ?? org, headline: title, kind: "Page")
        }
        if let key = query["selectedIssue"] { return s("Jira", "#0052CC", "checkmark.square", context: org, headline: key, kind: "Issue") }
    case host == "linear.app":
        if let i = parts.firstIndex(of: "issue"), let key = at(i + 1) {
            return s("Linear", "#5E6AD2", "circle.dashed", context: at(0) ?? "", headline: key, kind: "Issue", detail: at(i + 2).map(humanize))
        }
        if let i = parts.firstIndex(of: "project"), let name = at(i + 1) {
            return s("Linear", "#5E6AD2", "square.stack.3d.up", context: at(0) ?? "", headline: humanize(name), kind: "Project")
        }
    case host == "notion.so" || host.hasSuffix(".notion.site"):
        if let last = parts.last { return s("Notion", "#191919", "doc.text", context: parts.count > 1 ? parts[0] : label, headline: humanize(last), kind: "Page") }
    case host == "figma.com":
        let kinds = ["file": "Design", "design": "Design", "board": "FigJam board", "proto": "Prototype", "slides": "Slides"]
        if let k = at(0), let kind = kinds[k] {
            return s("Figma", "#A259FF", "paintbrush.pointed", context: "Figma", headline: at(2).map(humanize) ?? "Untitled", kind: kind)
        }
    case host == "docs.google.com":
        let kinds = ["document": ("Google Docs", "#1A73E8", "doc.text", "Document"), "spreadsheets": ("Google Sheets", "#188038", "tablecells", "Spreadsheet"),
                     "presentation": ("Google Slides", "#F9AB00", "rectangle.on.rectangle", "Presentation"), "forms": ("Google Forms", "#7248B9", "list.bullet.rectangle", "Form")]
        if let k = at(0), let (site, color, symbol, kind) = kinds[k] {
            return s(site, color, symbol, context: "Google", headline: kind, kind: site)
        }
    case host == "drive.google.com":
        let folder = parts.contains("folders")
        return s("Google Drive", "#1FA463", folder ? "folder" : "doc", context: "Google", headline: folder ? "Folder" : "File", kind: folder ? "Folder" : "File")
    case host == "meet.google.com":
        if let code = at(0) { return s("Google Meet", "#00897B", "video", context: "Google", headline: code, kind: "Meeting") }
    case host.hasSuffix(".slack.com") || host == "app.slack.com":
        let workspace = host == "app.slack.com" ? "Slack" : label
        if parts.first == "archives" {
            return s("Slack", "#4A154B", "bubble.left", context: workspace, headline: parts.count >= 3 ? "Message" : "Channel",
                     kind: parts.count >= 3 ? "Message" : "Channel")
        }
        return s("Slack", "#4A154B", "bubble.left", context: workspace, headline: workspace, kind: "Workspace")
    case host == "youtube.com" || host == "m.youtube.com" || host == "youtu.be":
        let id = host == "youtu.be" ? at(0) : (query["v"] ?? (at(0) == "shorts" ? at(1) : nil))
        if id != nil { return s("YouTube", "#FF0000", "play.rectangle.fill", context: "YouTube", headline: at(0) == "shorts" ? "Short" : "Video", kind: "Video") }
    case host == "x.com" || host == "twitter.com":
        if let user = at(0), at(1) == "status" { return s("X", "#000000", "text.bubble", context: "X", headline: "@\(user)", kind: "Post") }
        if let user = at(0) { return s("X", "#000000", "person", context: "X", headline: "@\(user)", kind: "Profile") }
    case host == "linkedin.com":
        if at(0) == "in", let name = at(1) { return s("LinkedIn", "#0A66C2", "person", context: "LinkedIn", headline: humanize(name), kind: "Profile") }
        if at(0) == "posts" || at(0) == "feed" { return s("LinkedIn", "#0A66C2", "text.bubble", context: "LinkedIn", headline: "Post", kind: "Post") }
        if at(0) == "company", let name = at(1) { return s("LinkedIn", "#0A66C2", "building.2", context: "LinkedIn", headline: humanize(name), kind: "Company") }
    case host == "stackoverflow.com" || host.hasSuffix(".stackexchange.com") || host == "superuser.com" || host == "serverfault.com":
        if at(0) == "questions", let slug = at(2) {
            return s(host == "stackoverflow.com" ? "Stack Overflow" : siteName(host), "#F48024", "questionmark.bubble", context: label, headline: humanize(slug), kind: "Question")
        }
    case host == "reddit.com" || host == "old.reddit.com":
        if at(0) == "r", let sub = at(1) {
            let title = at(2) == "comments" ? at(4).map(humanize) : nil
            return s("Reddit", "#FF4500", "bubble.left.and.bubble.right", context: "Reddit", headline: title ?? "r/\(sub)", kind: "r/\(sub)")
        }
    case host.hasSuffix("wikipedia.org"):
        if at(0) == "wiki", let title = at(1) {
            return s("Wikipedia", "#636466", "book", context: label, headline: title.replacingOccurrences(of: "_", with: " "), kind: "Article")
        }
    case host == "npmjs.com":
        if at(0) == "package", let name = parts.dropFirst().joined(separator: "/").nilIfEmpty {
            return s("npm", "#CB3837", "shippingbox", context: "npm", headline: name, kind: "npm package")
        }
    case host == "pypi.org":
        if at(0) == "project", let name = at(1) { return s("PyPI", "#3775A9", "shippingbox", context: "PyPI", headline: name, kind: "PyPI package") }
    case host.hasSuffix("zoom.us"):
        if at(0) == "j" || at(0) == "my" { return s("Zoom", "#2D8CFF", "video", context: "Zoom", headline: "Meeting", kind: "Meeting") }
    default:
        break
    }
    // Grafana-style dashboards on any host: /d/<uid>/<slug>
    if at(0) == "d", let slug = at(2) {
        return s(siteName(host), color(for: host), "chart.xyaxis.line", context: host, headline: humanize(slug), kind: "Dashboard")
    }
    let page = parts.reversed().first(where: isReadableSegment).map(humanize)
    return s(siteName(host), color(for: host), nil, context: host, headline: page ?? siteName(host), kind: host)
}

/// A site's display name: the main part of its domain, capitalized ("news.ycombinator.com" -> "Ycombinator").
func siteName(_ host: String) -> String {
    let labels = host.split(separator: ".").map(String.init)
    let generic: Set<String> = ["com", "org", "net", "io", "co", "app", "dev", "ai", "in", "uk", "us", "edu", "gov"]
    let main = labels.dropLast().last { !generic.contains($0) } ?? labels.first ?? host
    return main.prefix(1).uppercased() + main.dropFirst()
}

/// The same pleasant colour for a site every time.
func color(for host: String) -> String {
    let palette = ["#2F6FEB", "#1F9D55", "#C2410C", "#7C3AED", "#0E7490", "#BE185D", "#4D7C0F", "#B45309", "#475569"]
    let sum = host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    return palette[sum % palette.count]
}

/// A path segment worth showing: not an id (all digits, long hex, a UUID), not too short.
func isReadableSegment(_ s: String) -> Bool {
    let base = (s as NSString).deletingPathExtension
    guard base.count >= 2, base.contains(where: \.isLetter) else { return false }
    let hexish = base.filter { !$0.isHexDigit && $0 != "-" }.isEmpty
    return !(hexish && base.count >= 12)
}

/// "how-to-ship_fast.html" -> "How to ship fast"; a trailing 32-character id (Notion) is dropped.
func humanize(_ s: String) -> String {
    var base = (s as NSString).deletingPathExtension
    if base.count > 33, base.suffix(32).allSatisfy(\.isHexDigit) { base = String(base.dropLast(32)) }
    let words = base.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "+" || $0 == " " }).map(String.init)
        .filter { !$0.isEmpty }
    guard let first = words.first else { return s }
    let text = ([first.prefix(1).uppercased() + first.dropFirst().lowercased()] + words.dropFirst().map { $0.lowercased() }).joined(separator: " ")
    return text.count > 80 ? String(text.prefix(79)) + "…" : text
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A page title without the site (and place) it repeats: "Fix sync · Issue #12 · owner/repo · GitHub" -> "Fix sync",
/// "Pricing | Linear" -> "Pricing". A trailing part is dropped only when it names the site, so "A - B testing" stays.
public func cleanPageTitle(_ title: String, site: String) -> String {
    var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.contains(" · "), let first = t.components(separatedBy: " · ").first, !first.isEmpty { return first }
    let siteWord = site.lowercased()
    for sep in [" | ", " — ", " – ", " - "] {
        guard let r = t.range(of: sep, options: .backwards) else { continue }
        let tail = t[r.upperBound...].lowercased()
        if tail.contains(siteWord) || siteWord.contains(tail) {
            t = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            break
        }
    }
    return t
}
