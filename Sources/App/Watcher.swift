import AppKit

/// Watches the general pasteboard's change count and stores each new copy.
/// Contents are read only while macOS allows it without asking (`accessBehavior == .alwaysAllow`): under `.ask`
/// every read raises the system alert again, so Mneme stops capturing and says so instead (docs/spike-notes.md).
@MainActor
final class Watcher {
    private let store: Store
    private let storeQueue: DispatchQueue
    private let rules: () -> CaptureRules
    private let onCapture: (Item) -> Void
    private let pasteboard = NSPasteboard.general
    private var timer: DispatchSourceTimer?
    private var lastChange: Int
    private var ticks = 0
    private let captureQueue = DispatchQueue(label: "local.mneme.capture", qos: .userInitiated)
    /// Apps that came to the front since the last copy was looked at (see CaptureRules.recentBundleIDs).
    private var recentApps = Set<String>()
    private var activation: NSObjectProtocol?
    private(set) var captureAllowed = Watcher.accessAllowed()
    var onAccessChange: ((Bool) -> Void)?
    /// Each stored copy with the clipboard's change count at the time. Runs on the store queue.
    var onCopied: (@Sendable (Capture, Int) -> Void)?

    init(store: Store, storeQueue: DispatchQueue, rules: @escaping () -> CaptureRules, onCapture: @escaping (Item) -> Void) {
        self.store = store
        self.storeQueue = storeQueue
        self.rules = rules
        self.onCapture = onCapture
        lastChange = NSPasteboard.general.changeCount
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                       object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if let id { self?.recentApps.insert(id) } }
        }
    }

    /// Reading this never raises the alert.
    static func accessAllowed() -> Bool {
        guard #available(macOS 15.4, *) else { return true }
        return NSPasteboard.general.accessBehavior == .alwaysAllow
    }

    /// The one deliberate read, from setup: it makes macOS list Mneme under Paste from Other Apps so the user can
    /// choose Always Allow there. Only when Mneme has never been asked (a read under Ask would raise the alert again).
    static func introduceToPasteboardPrivacy() {
        guard #available(macOS 15.4, *), NSPasteboard.general.accessBehavior == .default else { return }
        _ = NSPasteboard.general.string(forType: .string)
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func refreshAccess() {
        let allowed = Watcher.accessAllowed()
        if allowed != captureAllowed {
            captureAllowed = allowed
            onAccessChange?(allowed)
        }
    }

    private func tick() {
        ticks += 1
        if !captureAllowed, ticks % 10 == 0 { refreshAccess() }
        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        lastChange = count
        refreshAccess()
        guard captureAllowed else { return }
        let app = NSWorkspace.shared.frontmostApplication
        let source = app.flatMap { a in a.bundleIdentifier.map { SourceApp(bundleID: $0, name: a.localizedName ?? $0) } }
        var r = rules()
        r.recentBundleIDs = recentApps
        recentApps = Set([source?.bundleID].compactMap { $0 })
        // Reading can be slow (a big image, an app that makes its data on request): never on the main thread.
        captureQueue.async { [store, storeQueue, onCapture, onCopied] in
          let snap = snapshot(of: .general, rules: r, source: source)
          storeQueue.async {
            guard case .success(let capture) = classify(snap, source: source, rules: r),
                  var item = try? store.ingest(capture, now: Date()) else { return }
            if item.kind == .image, item.thumb == nil {
                item = storeThumbnail(store, item, imageData: capture.representations.first { PasteType.images.contains($0.type) }?.data)
            }
            onCopied?(capture, snap.changeCount)
            DispatchQueue.main.async { onCapture(item) }
          }
        }
    }
}
