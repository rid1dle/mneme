import AppKit
import ApplicationServices

/// Gives each app the form of a text copy that suits it (PasteRules): when an app comes to the front (so Edit >
/// Paste gets it too), on ⌘V (from the key watcher's thread, before the key reaches the app, which also covers a
/// browser tab switch), on a paste from the shelf or the paste stack, and on the plain and original shortcuts. The clipboard is only rewritten when the app in front should get a different form than the one on it.
///
/// The copy's forms are built once, off the main thread, when it is copied. Called from the main thread and the key
/// watcher's thread, so its state is locked.
final class PasteFormatter: @unchecked Sendable {
    private struct Managed {
        var versions: PasteVersions
        /// False for copies Mneme does not reformat (images, files, a spreadsheet's copy): they keep the original
        /// except when the user asks for plain text.
        var reformats: Bool
        var markdown: Bool
        var source: String?
        var sourceName: String?
        /// The clipboard's change count while it holds this copy.
        var changeCount: Int
        var current: PasteVersion
        /// Plain text differs by place (dashes for code, dots for chats).
        var bullets: BulletStyle = .dots
    }

    private let lock = NSLock()
    private var managed: Managed?
    private var front: (bundle: String?, name: String?, pid: pid_t) = (nil, nil, 0)
    private var learning: PasteLearning
    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private let logURL: URL?
    private let queue = DispatchQueue(label: "local.mneme.format", qos: .userInitiated)
    private var activation: NSObjectProtocol?
    /// Main thread: a write of Mneme's own, so the watcher does not store it again.
    var onOwnWrite: (Int) -> Void = { _ in }

    init(pasteboard: NSPasteboard = .general, defaults: UserDefaults = .standard, logURL: URL?) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.logURL = logURL
        learning = defaults.data(forKey: Pref.pasteLearning).flatMap { try? JSONDecoder().decode(PasteLearning.self, from: $0) } ?? PasteLearning()
    }

    /// Follows the app in front, so ⌘V knows where it goes without asking AppKit off the main thread.
    @MainActor
    func watchFrontApp() {
        setFront(NSWorkspace.shared.frontmostApplication)
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontMoved(bundle: app?.bundleIdentifier, name: app?.localizedName, pid: app?.processIdentifier ?? 0)
        }
    }

    /// Another app came to the front: the clipboard is put in its form now, so a paste from its Edit menu or a right
    /// click gets it too, not only ⌘V.
    func frontMoved(bundle: String?, name: String?, pid: pid_t) {
        setFront(bundle: bundle, name: name, pid: pid)
        apply(via: nil)
    }

    private func setFront(_ app: NSRunningApplication?) {
        setFront(bundle: app?.bundleIdentifier, name: app?.localizedName, pid: app?.processIdentifier ?? 0)
    }

    func setFront(bundle: String?, name: String?, pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        front = (bundle, name, pid)
    }

    // MARK: copies

    /// A new copy was stored. Its forms are built off the main thread; until then ⌘V pastes it as copied.
    func copied(_ reps: [Representation], source: SourceApp?, changeCount: Int) {
        queue.async { [self] in
            let versions = pasteVersions(reps, sourceBundle: source?.bundleID, richTextToHTML: htmlFromRichText)
            lock.lock()
            if let versions {
                managed = Managed(versions: versions, reformats: true, markdown: isMarkdown(reps), source: source?.bundleID,
                                  sourceName: source?.name, changeCount: changeCount, current: .original)
            } else if managed.map({ $0.changeCount <= changeCount }) ?? true {
                managed = nil
            }
            lock.unlock()
            // The user may already be in the app they will paste into.
            if versions != nil { apply(via: nil) }
        }
    }

    private func isMarkdown(_ reps: [Representation]) -> Bool {
        guard !reps.contains(where: { PasteType.rich.contains($0.type) }) else { return false }
        return reps.first { $0.type == PasteType.plain }.flatMap { String(data: $0.data, encoding: .utf8) }.map(looksLikeMarkdown) ?? false
    }

    // MARK: paste stack

    private var stackSources: [String: SourceApp] = [:]

    /// Where each stacked item was copied, by content hash, so the stack's items get the same treatment.
    func setStackSources(_ sources: [String: SourceApp]) {
        lock.lock(); defer { lock.unlock() }
        stackSources = sources
    }

    /// The paste stack just put an item on the clipboard (main thread or the key watcher's thread): it is formatted
    /// like any copy, at once for the app in front.
    func adoptStackItem(_ reps: [Representation], changeCount: Int) {
        lock.lock()
        let source = stackSources[contentHash(reps)]
        lock.unlock()
        let versions = pasteVersions(reps, sourceBundle: source?.bundleID, richTextToHTML: htmlFromRichText)
        lock.lock()
        managed = versions.map { Managed(versions: $0, reformats: true, markdown: isMarkdown(reps), source: source?.bundleID,
                                         sourceName: source?.name, changeCount: changeCount, current: .original) }
        lock.unlock()
        apply(via: nil)
    }

    /// Waits for copies being prepared (tests).
    func settle() { queue.sync {} }

    // MARK: ⌘V

    /// The key watcher's thread, before the ⌘V reaches the app.
    func commandV() { apply(via: "cmd-v") }

    /// Puts the copy in the form for the app in front, if it is not already; `via` names a paste to log.
    private func apply(via: String?) {
        guard defaults.bool(forKey: Pref.formatOnCommandV) else { return }
        lock.lock(); defer { lock.unlock() }
        // Unknown app in front: nowhere to suit, leave the clipboard as it is.
        guard var m = managed, pasteboard.changeCount == m.changeCount, front.bundle != nil else { return }
        let place = place(m.source, front.bundle, front.pid)
        let v = m.versions.effective(m.reformats ? PasteRules.version(for: place, learned: learning) : .original)
        if v != m.current || (v == .plain && m.bullets != place.target.bullets) {
            write(&m, v, target: place.target)
            managed = m
        }
        if let via { log(place, v, reason: m.reformats ? pasteReason(place, learned: learning) : "not-reformatted", via: via, markdown: m.markdown) }
    }

    /// Locked.
    private func write(_ m: inout Managed, _ v: PasteVersion, target: PasteTarget) {
        let count = Paster.write(m.versions.representations(v, target: target), plainText: false, fallbackText: nil, to: pasteboard)
        m.changeCount = count
        m.current = v
        m.bullets = target.bullets
        DispatchQueue.main.async { [onOwnWrite] in onOwnWrite(count) }
    }

    // MARK: pastes Mneme makes

    /// Puts a stored item on the clipboard in the form for `target` (nil: only copying, so as copied), or in the
    /// form the user chose, which is learned for that place. Main thread. Returns the clipboard's change count.
    @MainActor
    func put(_ reps: [Representation], text: String?, source: SourceApp?, target: NSRunningApplication?, as chosen: PasteVersion?) -> Int {
        let built = pasteVersions(reps, sourceBundle: source?.bundleID, richTextToHTML: htmlFromRichText)
        let plain = text ?? reps.first { $0.type == PasteType.plain }.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        let versions = built ?? PasteVersions(original: reps, clean: reps, plainDots: plain, plainDashes: plain)
        let markdown = built != nil && isMarkdown(reps)
        var m = Managed(versions: versions, reformats: built != nil, markdown: markdown, source: source?.bundleID,
                        sourceName: source?.name, changeCount: -1, current: .original)
        lock.lock(); defer { lock.unlock() }
        guard let target else {
            write(&m, chosen ?? .original, target: .rich)
            managed = m
            return m.changeCount
        }
        let place = place(m.source, target.bundleIdentifier, target.processIdentifier)
        let smart = defaults.bool(forKey: Pref.formatFromMneme) && m.reformats
        let v = chosen ?? (smart ? PasteRules.version(for: place, learned: learning) : .original)
        write(&m, v, target: place.target)
        managed = m
        if let chosen { learn(chosen, place, targetName: target.localizedName) }
        log(place, v, reason: chosen != nil ? "chosen" : smart ? pasteReason(place, learned: learning) : "off", via: "shelf", markdown: m.markdown)
        return m.changeCount
    }

    /// The plain and original shortcuts: puts the clipboard as it is now on it again in that form, for `target`
    /// (the app in front), and learns the choice there. False when there is no text for plain text. Main thread;
    /// the caller then presses ⌘V.
    @MainActor
    func takeNow(_ v: PasteVersion, target: NSRunningApplication?) -> Bool {
        takeNow(v, targetBundle: target?.bundleIdentifier, targetName: target?.localizedName, pid: target?.processIdentifier ?? 0)
    }

    func takeNow(_ v: PasteVersion, targetBundle: String?, targetName: String?, pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var m: Managed
        if let current = managed, current.changeCount == pasteboard.changeCount {
            m = current
        } else {
            // Not a copy Mneme has seen (taken while capture was off or paused): read it now.
            let snap = snapshot(of: pasteboard)
            let reps = (snap.items.first ?? [:]).map { Representation(index: 0, type: $0.key, data: $0.value) }.sorted { $0.type < $1.type }
            guard !reps.isEmpty else { return false }
            let built = pasteVersions(reps, sourceBundle: nil, richTextToHTML: htmlFromRichText)
            let plain = reps.first { $0.type == PasteType.plain }.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
            m = Managed(versions: built ?? PasteVersions(original: reps, clean: reps, plainDots: plain, plainDashes: plain),
                        reformats: built != nil, markdown: false, source: nil, sourceName: nil, changeCount: snap.changeCount, current: .original)
        }
        if v == .plain, m.versions.plainDots.isEmpty { return false }
        let place = place(m.source, targetBundle, pid)
        write(&m, v, target: place.target)
        managed = m
        learn(v, place, targetName: targetName)
        log(place, v, reason: "chosen", via: "shortcut", markdown: m.markdown)
        return true
    }

    // MARK: learning

    /// Locked.
    private func learn(_ v: PasteVersion, _ place: PastePlace, targetName: String?) {
        let from = managed?.sourceName ?? "Anywhere"
        let to = place.site.map { "\($0) (\(targetName ?? "browser"))" } ?? targetName ?? place.targetBundle ?? "?"
        learning.record(v, key: place.learningKey, name: "\(from) to \(to)")
        if let data = try? JSONEncoder().encode(learning) { defaults.set(data, forKey: Pref.pasteLearning) }
    }

    var learnedRules: [(key: String, name: String, version: PasteVersion)] {
        lock.lock(); defer { lock.unlock() }
        return learning.rules
    }

    func forget(_ key: String?) {
        lock.lock(); defer { lock.unlock() }
        if let key { learning.forget(key) } else { learning = PasteLearning() }
        if let data = try? JSONEncoder().encode(learning) { defaults.set(data, forKey: Pref.pasteLearning) }
    }

    // MARK: where a paste goes

    /// A browser's front window title, which names the site (Gmail, Google Sheets). Asked with a short timeout: a
    /// busy browser must not hold up the ⌘V.
    private func place(_ source: String?, _ bundle: String?, _ pid: pid_t) -> PastePlace {
        PastePlace(sourceBundle: source, targetBundle: bundle, windowTitle: title(bundle, pid), inTerminal: inTerminal(bundle, pid))
    }

    /// True when a code editor's built-in terminal has the keyboard: its focused element is xterm.js's input field.
    private func inTerminal(_ bundle: String?, _ pid: pid_t) -> Bool {
        guard let bundle, PasteRules.editorsWithTerminal.contains(bundle), pid > 0, AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        var classes: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, "AXDOMClassList" as CFString, &classes) == .success else { return false }
        return (classes as? [String])?.contains("xterm-helper-textarea") == true
    }

    private func title(_ bundle: String?, _ pid: pid_t) -> String? {
        guard let bundle, PasteRules.browsers.contains(bundle), pid > 0, AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    // MARK: log

    /// One JSON line per paste (apps, site, form and why; never the content), for refining the rules from real use.
    /// Kept under 1 MB, the previous file kept as .1.
    private func log(_ place: PastePlace, _ v: PasteVersion, reason: String, via: String, markdown: Bool) {
        guard let logURL else { return }
        let entry = PasteLogEntry(time: Date(), place: place, version: v, reason: reason, via: via, markdown: markdown)
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0a)
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 1_000_000 {
                let old = logURL.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: logURL, to: old)
            }
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile()
                h.write(line)
                try? h.close()
            } else {
                try? line.write(to: logURL)
            }
        }
    }
}
