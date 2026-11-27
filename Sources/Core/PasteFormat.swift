import Foundation

/// Which form of a text copy an app gets.
public enum PasteVersion: String, Codable, CaseIterable, Sendable {
    /// Exactly what was copied, colours and fonts included.
    case original
    /// Structure kept (lists, bold, links, code, tables), colours, backgrounds and fonts dropped.
    case clean
    /// Text only, with bullets and indents rebuilt.
    case plain
    /// Text with the structure written as Markdown (bold, numbered lists, tables), for code editors, terminals and
    /// the AI chat boxes in them. A copy with no such structure is pasted as it was copied.
    case markdown

    public var name: String {
        switch self {
        case .original: return "Original formatting"
        case .clean: return "Clean formatting"
        case .plain: return "Plain text"
        case .markdown: return "Markdown"
        }
    }
}

/// What kind of place a paste goes into, which sets the version it gets unless the user taught otherwise.
public enum PasteTarget: String, Sendable {
    /// Excel, Numbers, Google Sheets: colours and cell styling are part of the content there.
    case spreadsheet
    /// Code editors and the AI chat boxes in them: Markdown.
    case code
    /// Terminals, including the one inside a code editor: text only, no bullets or indents.
    case terminal
    /// Chats that take text only: text with bullet characters.
    case plainChat
    /// Mail, documents, notes, chat apps that read formatting: structure without looks.
    case rich

    public var version: PasteVersion {
        switch self {
        case .spreadsheet: return .original
        case .code: return .markdown
        case .terminal, .plainChat: return .plain
        case .rich: return .clean
        }
    }

    public var bullets: BulletStyle {
        switch self {
        case .code: return .dashes
        case .terminal: return .bare
        default: return .dots
        }
    }
}

/// The app (and, in a browser, the site) a paste goes into, and where the copy came from.
public struct PastePlace: Equatable, Sendable {
    public var sourceBundle: String?
    public var targetBundle: String?
    public var windowTitle: String?
    /// The paste goes into a code editor's built-in terminal.
    public var inTerminal: Bool
    public init(sourceBundle: String?, targetBundle: String?, windowTitle: String? = nil, inTerminal: Bool = false) {
        self.sourceBundle = sourceBundle; self.targetBundle = targetBundle; self.windowTitle = windowTitle; self.inTerminal = inTerminal
    }

    /// For a browser: the site from the window title ("Inbox - Gmail" is Gmail). Nil for other apps.
    public var site: String? {
        guard let b = targetBundle, PasteRules.browsers.contains(b), let t = windowTitle, !t.isEmpty else { return nil }
        for (needle, name) in PasteRules.knownSites where t.localizedCaseInsensitiveContains(needle) { return name }
        let last = t.components(separatedBy: " - ").last?.trimmingCharacters(in: .whitespaces) ?? t
        return last.isEmpty ? nil : String(last.prefix(40))
    }

    public var target: PasteTarget { inTerminal ? .terminal : PasteRules.target(bundle: targetBundle, site: site) }

    /// The key the user's choices are learned under: where from, where to.
    public var learningKey: String {
        "\(sourceBundle ?? "?")>\(targetBundle ?? "?")" + (site.map { "|\($0)" } ?? "") + (inTerminal ? "|terminal" : "")
    }
}

public enum PasteRules {
    public static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "app.zen-browser.zen", "org.mozilla.firefox", "com.apple.Safari",
        "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.chromium.Chromium", "com.kagi.kagimacOS",
    ]

    /// Window title text that names a site, checked in order.
    static let knownSites: [(String, String)] = [
        ("Google Sheets", "Google Sheets"), ("Google Docs", "Google Docs"), ("Google Slides", "Google Slides"),
        ("Gmail", "Gmail"), ("Outlook", "Outlook"), ("WhatsApp", "WhatsApp"), ("Telegram", "Telegram"), ("Slack", "Slack"),
        ("Notion", "Notion"), ("Airtable", "Airtable"), ("Smartsheet", "Smartsheet"), (".xlsx", "Excel"), (" - Excel", "Excel"),
        ("Jira", "Jira"), ("Confluence", "Confluence"), ("Linear", "Linear"), ("GitHub", "GitHub"), ("ChatGPT", "ChatGPT"),
        ("Claude", "Claude"),
    ]

    static let spreadsheets: Set<String> = ["com.microsoft.Excel", "com.apple.iWork.Numbers", "org.libreoffice.script", "com.apple.Numbers"]
    static let spreadsheetSites: Set<String> = ["Google Sheets", "Excel", "Airtable", "Smartsheet"]

    static let codeApps: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "com.apple.dt.Xcode", "dev.zed.Zed", "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova", "com.barebones.bbedit",
        "org.vim.MacVim", "com.vscodium",
    ]
    static let codePrefixes = ["com.jetbrains."]

    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "io.alacritty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio",
    ]

    /// Code editors whose built-in terminal can be told apart from the editor by the focused element (VS Code and its
    /// forks: xterm.js's input field).
    public static let editorsWithTerminal: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "com.vscodium",
    ]

    static let plainChats: Set<String> = [
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram", "org.telegram.desktop", "com.apple.MobileSMS",
        "com.hnc.Discord", "org.whispersystems.signal-desktop",
    ]
    static let plainChatSites: Set<String> = ["WhatsApp", "Telegram"]

    public static func target(bundle: String?, site: String?) -> PasteTarget {
        guard let bundle else { return .rich }
        if let site {
            if spreadsheetSites.contains(site) { return .spreadsheet }
            if plainChatSites.contains(site) { return .plainChat }
            return .rich
        }
        if spreadsheets.contains(bundle) { return .spreadsheet }
        if terminals.contains(bundle) { return .terminal }
        if codeApps.contains(bundle) || codePrefixes.contains(where: bundle.hasPrefix) { return .code }
        if plainChats.contains(bundle) { return .plainChat }
        return .rich
    }

    /// A copy from a spreadsheet is left alone: its cell styling is content and its plain text is already tab
    /// separated, which is what any other app should get.
    public static func managesCopy(from bundle: String?) -> Bool {
        guard let bundle else { return true }
        return !spreadsheets.contains(bundle)
    }

    /// The version for a paste: the original back into the app it came from, then what the user taught for this
    /// place, then the rule for the kind of place.
    public static func version(for place: PastePlace, learned: PasteLearning) -> PasteVersion {
        if backHome(place) { return .original }
        return learned.version(for: place.learningKey) ?? place.target.version
    }

    /// Back into the app the copy came from. Not for a code editor or terminal: a copy from its chat or preview
    /// panel has a list or table that only Markdown keeps (its own editor copies have none, so they paste as copied
    /// anyway), and a terminal takes text without indents even from itself.
    static func backHome(_ place: PastePlace) -> Bool {
        guard let s = place.sourceBundle, s == place.targetBundle, place.site == nil else { return false }
        return place.target != .code && place.target != .terminal
    }
}

/// The user's own choices (the plain or original shortcuts, ⇧↩ and ⌥↩ in the shelf) per place. Two choices in a row
/// the same way for one place make that the rule there; choosing differently twice changes it.
public struct PasteLearning: Codable, Equatable, Sendable {
    public var choices: [String: [PasteVersion]] = [:]
    /// Readable names for each key, for Settings.
    public var names: [String: String] = [:]
    public init() {}

    static let kept = 5

    public mutating func record(_ v: PasteVersion, key: String, name: String? = nil) {
        var list = choices[key] ?? []
        list.append(v)
        choices[key] = Array(list.suffix(Self.kept))
        if let name { names[key] = name }
    }

    public func version(for key: String) -> PasteVersion? {
        guard let list = choices[key], list.count >= 2, list[list.count - 1] == list[list.count - 2] else { return nil }
        return list.last
    }

    public mutating func forget(_ key: String) { choices[key] = nil; names[key] = nil }

    /// What has become a rule, for Settings.
    public var rules: [(key: String, name: String, version: PasteVersion)] {
        choices.keys.sorted().compactMap { k in version(for: k).map { (k, names[k] ?? k, $0) } }
    }
}

/// The three forms of one text copy, built once when it is copied.
public struct PasteVersions: Sendable {
    public var original: [Representation]
    public var clean: [Representation]
    /// Plain text per bullet style.
    public var plainDots: String
    public var plainDashes: String
    /// Nil when the copy has nothing only Markdown carries; the original is pasted instead.
    public var markdown: String? = nil
    /// For a terminal: no bullets, Markdown or indents. Nil: the copy's plain text with dashes.
    public var bare: String? = nil

    /// The version that is really pasted: the original when the asked one would be the same as the copy.
    public func effective(_ v: PasteVersion) -> PasteVersion {
        switch v {
        case .markdown where markdown == nil: return .original
        case .clean where clean == original: return .original
        default: return v
        }
    }

    public func representations(_ v: PasteVersion, target: PasteTarget) -> [Representation] {
        switch v {
        case .original: return original
        case .clean: return clean
        case .plain:
            let text: String
            switch target.bullets {
            case .dashes, .markdown: text = plainDashes
            case .bare: text = bare ?? plainDashes
            case .dots: text = plainDots
            }
            return [Representation(index: 0, type: PasteType.plain, data: Data(text.utf8))]
        case .markdown:
            guard let markdown else { return original }
            return [Representation(index: 0, type: PasteType.plain, data: Data(markdown.utf8))]
        }
    }
}

/// Bigger HTML than this is pasted as it is (a whole web page, a huge table): cleaning it at ⌘V would be noticeable.
public let maxFormattedHTMLBytes = 2_000_000

/// The versions for a copy, or nil when there is nothing to improve: no HTML, rich text, Markdown-looking or indented
/// text, several clipboard items, files or images, or a spreadsheet's copy. `richTextToHTML` reads RTF (true: RTFD) into
/// clean HTML; it needs AppKit, so the app passes it in.
public func pasteVersions(_ reps: [Representation], sourceBundle: String?, richTextToHTML: ((Data, Bool) -> String?)? = nil) -> PasteVersions? {
    guard PasteRules.managesCopy(from: sourceBundle), !reps.isEmpty, reps.allSatisfy({ $0.index == 0 }) else { return nil }
    let types = Set(reps.map(\.type))
    if types.contains(PasteType.fileURL) || !types.isDisjoint(with: PasteType.images) { return nil }
    let plain = reps.first { $0.type == PasteType.plain }.flatMap { String(data: $0.data, encoding: .utf8) }
    if let htmlRep = reps.first(where: { $0.type == PasteType.html }) {
        guard htmlRep.data.count <= maxFormattedHTMLBytes, let html = String(data: htmlRep.data, encoding: .utf8) else { return nil }
        let clean = cleanHTML(html)
        let list = htmlHasList(html)
        let dots = list || plain == nil ? plainText(fromHTML: html, bullets: .dots) : plain!
        let dashes = list || plain == nil ? plainText(fromHTML: html, bullets: .dashes) : plain!
        return PasteVersions(original: reps,
                             clean: [Representation(type: PasteType.html, data: Data(clean.utf8)), Representation(type: PasteType.plain, data: Data(dots.utf8))],
                             plainDots: dots, plainDashes: dashes, markdown: markdownText(fromHTML: html),
                             bare: plainText(fromHTML: clean, bullets: .bare))
    }
    if let rich = reps.first(where: { $0.type == PasteType.rtfd }) ?? reps.first(where: { $0.type == PasteType.rtf }) {
        guard rich.data.count <= maxFormattedHTMLBytes, let html = richTextToHTML?(rich.data, rich.type == PasteType.rtfd) else { return nil }
        let list = htmlHasList(html)
        let dots = list || plain == nil ? plainText(fromHTML: html, bullets: .dots) : plain!
        let dashes = list || plain == nil ? plainText(fromHTML: html, bullets: .dashes) : plain!
        return PasteVersions(original: reps,
                             clean: [Representation(type: PasteType.html, data: Data(html.utf8)), Representation(type: PasteType.plain, data: Data(dots.utf8))],
                             plainDots: dots, plainDashes: dashes, markdown: markdownText(fromHTML: html),
                             bare: plainText(fromHTML: html, bullets: .bare))
    }
    guard let plain else { return nil }
    guard looksLikeMarkdown(plain) else {
        // Indented text (a command copied from a terminal's output) only changes for a terminal.
        let flush = dedented(plain)
        guard flush != plain else { return nil }
        return PasteVersions(original: reps, clean: reps, plainDots: plain, plainDashes: plain, bare: flush)
    }
    let html = markdownToHTML(plain)
    return PasteVersions(original: reps,
                         clean: [Representation(type: PasteType.html, data: Data(html.utf8)), Representation(type: PasteType.plain, data: Data(plain.utf8))],
                         plainDots: plain, plainDashes: plain, markdown: plain, bare: plainText(fromHTML: html, bullets: .bare))
}

/// One line of the paste log: no content, only where from, where to, what was given and why.
public struct PasteLogEntry: Codable, Equatable, Sendable {
    public var time: Date
    public var source: String?
    public var target: String?
    public var site: String?
    public var version: PasteVersion
    /// "rule", "learned", "same-app", or "chosen" when the user picked it.
    public var reason: String
    /// "cmd-v", "shelf", "shortcut".
    public var via: String
    public var markdown: Bool

    public init(time: Date, place: PastePlace, version: PasteVersion, reason: String, via: String, markdown: Bool) {
        self.time = time; source = place.sourceBundle; target = place.targetBundle; site = place.site
        self.version = version; self.reason = reason; self.via = via; self.markdown = markdown
    }
}

public func pasteReason(_ place: PastePlace, learned: PasteLearning) -> String {
    if PasteRules.backHome(place) { return "same-app" }
    return learned.version(for: place.learningKey) != nil ? "learned" : "rule"
}
