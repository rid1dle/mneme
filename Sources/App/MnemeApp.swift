import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// Launch options used for testing (flags without a value go last):
///   --store <dir>           use this store folder instead of ~/Library/Application Support/Mneme
///   --snapshot <png>        open the shelf off screen, draw it into a PNG and quit (no watcher, shortcut or menu bar)
///   --appearance light|dark, --theme <preset index>, --shell glass|solid, --width <points>
///   --search <text>, --kind text|image|link|file|color, --pinboard <name>, --select <n>
///   --overlay preview|edit|rename|newboard|delete, --stack <n>   (snapshots) open a sheet, or show n stacked items
///   --settings <tab>, --setup   (with --snapshot) draw Settings or the first-launch setup instead of the shelf
///   --measure <cycles>      open and close the shelf off screen, print first-frame times, then stay idle
///   --scroll <steps>        step the selection back and forth off screen and print frame times
///   --log                   print each capture to stderr
struct LaunchOptions {
    var store: String?
    var snapshot: String?
    var appearance: Appearance?
    var themePreset: Int?
    var shelfStyle: ShelfStyle?
    var shelfWidth: CGFloat?
    var search: String?
    var kind: ItemKind?
    var pinboard: String?
    var select = 0
    var measure: Int?
    var scroll: Int?
    var overlay: String?
    var stack = 0
    var settingsTab: String?
    var setup = false
    var stackPanel: Int?
    var log = false

    static let current = parse(CommandLine.arguments)

    var offscreen: Bool { snapshot != nil || measure != nil || scroll != nil }
    var snapshotsWindow: Bool { snapshot != nil && (settingsTab != nil || setup || stackPanel != nil) }

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--store": o.store = next()
            case "--snapshot": o.snapshot = next()
            case "--appearance": o.appearance = next().flatMap(Appearance.init(rawValue:))
            case "--theme": o.themePreset = next().flatMap(Int.init)
            case "--shell": o.shelfStyle = next().flatMap(ShelfStyle.init(rawValue:))
            case "--width": o.shelfWidth = next().flatMap(Double.init).map { CGFloat($0) }
            case "--search": o.search = next()
            case "--kind": o.kind = next().flatMap(ItemKind.init(rawValue:))
            case "--pinboard": o.pinboard = next()
            case "--select": o.select = next().flatMap(Int.init) ?? 0
            case "--measure": o.measure = next().flatMap(Int.init)
            case "--scroll": o.scroll = next().flatMap(Int.init)
            case "--overlay": o.overlay = next()
            case "--stack": o.stack = next().flatMap(Int.init) ?? 0
            case "--settings": o.settingsTab = next()
            case "--setup": o.setup = true
            case "--stack-panel": o.stackPanel = next().flatMap(Int.init)
            case "--log": o.log = true
            default: break
            }
            i += 1
        }
        return o
    }

    var storeDirectory: URL {
        if let store { return URL(fileURLWithPath: store, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mneme", isDirectory: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let storeQueue = DispatchQueue(label: "local.mneme.store", qos: .userInitiated)
    var store: Store!
    var watcher: Watcher!
    var theme: ThemeStore!
    var model: ShelfModel!
    var shelf: ShelfController!
    var stack = PasteStack()
    var paused = false
    var ownChangeCount: Int?
    private var globalHotkeys: [ShortcutAction: Hotkey] = [:]
    private var stackTap: StackTap!
    private var stackRelay: StackRelay!
    private var pendingFlush: DispatchWorkItem?
    private var stackPanel: StackPanelController!
    var shortcuts = Shortcuts.load()
    private var imageEditor: ImageEditor!
    private var ocr: OCRWorker!
    private var links: LinkFetcher!
    private var statusItem: NSStatusItem?
    private var retentionTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        Pref.register()
        let o = LaunchOptions.current
        // A locked store (another program reading it) is retried; only a damaged one is set aside, by Store itself.
        for attempt in 1...5 {
            do {
                store = try Store(directory: o.storeDirectory)
                break
            } catch {
                FileHandle.standardError.write("cannot open store (attempt \(attempt)): \(error)\n".data(using: .utf8)!)
                if attempt == 5 {
                    let alert = NSAlert()
                    alert.messageText = "Mneme cannot open its history"
                    alert.informativeText = "Another program may be using \(o.storeDirectory.path). Quit it and open Mneme again.\n\n\(error)"
                    alert.runModal()
                    NSApp.terminate(nil)
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        if let moved = store.recoveredFrom {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    Toast.show("Mneme's history file was damaged. It was set aside as \(moved.lastPathComponent) and a fresh one started.", seconds: 6)
                }
            }
        }
        // Test runs never write the user's theme.
        theme = ThemeStore(defaults: o.offscreen ? UserDefaults(suiteName: "local.mneme.test-runs")! : .standard)
        if o.offscreen {
            var t = o.themePreset.flatMap { themePresets.indices.contains($0) ? themePresets[$0].theme : nil } ?? themePresets[0].theme
            if let a = o.appearance { t.appearance = a }
            if let s = o.shelfStyle { t.shelf = s }
            theme.theme = t
        }
        theme.apply()
        model = ShelfModel(store: store, storeQueue: storeQueue)
        shelf = ShelfController(model: model, theme: theme, paster: Paster(store: store))
        shelf.offscreen = o.offscreen
        shelf.onOwnWrite = { [unowned self] count in ownChangeCount = count }
        imageEditor = ImageEditor(store: store, storeQueue: storeQueue) { [unowned self] in
            if shelf.isOpen { model.reload(keepSelection: true) }
            Toast.show("Image updated")
        }
        shelf.onEditImage = { [unowned self] item in imageEditor.edit(item) }
        let refresh = { [unowned self] in if shelf.isOpen { model.reload(keepSelection: true) } }
        ocr = OCRWorker(store: store, storeQueue: storeQueue, onRead: refresh)
        links = LinkFetcher(store: store, storeQueue: storeQueue, onFetched: refresh)
        shelf.onStopStack = { [unowned self] in toggleStack() }

        if let out = o.snapshot, o.snapshotsWindow { return runWindowSnapshot(to: out) }
        if let out = o.snapshot { return runSnapshot(to: out) }
        if let cycles = o.measure { return runMeasure(cycles: cycles) }
        if let steps = o.scroll { return runScroll(steps: steps) }

        watcher = Watcher(store: store, storeQueue: storeQueue, rules: { [unowned self] in
            captureRules(.standard, paused: paused, ownChangeCount: ownChangeCount)
        }, onCapture: { [unowned self] item in
            ocr.readSoon(item)
            if item.linkTitle == nil { links.fetch(item) }
            if stack.isOn {
                stack.add(item.id)
                refreshStackClipboard(writeHead: true)
                syncStack()
            }
            if o.log { FileHandle.standardError.write("captured \(item.kind.rawValue) from \(item.source?.name ?? "?"): \(item.preview.prefix(60))\n".data(using: .utf8)!) }
        })
        watcher.onAccessChange = { [unowned self] allowed in model.captureAllowed = allowed }
        model.captureAllowed = watcher.captureAllowed
        watcher.start()
        ocr.start()
        if o.log {
            FileHandle.standardError.write("permissions: accessibility=\(AXIsProcessTrusted()) clipboard=\(Watcher.accessAllowed()) path=\(Bundle.main.bundlePath)\n".data(using: .utf8)!)
        }
        globalHotkeys[.openShelf] = Hotkey(shortcuts[.openShelf]) { [unowned self] in shelf.toggle() }
        globalHotkeys[.toggleStack] = Hotkey(shortcuts[.toggleStack]) { [unowned self] in toggleStack() }
        globalHotkeys[.pasteNext] = Hotkey(shortcuts[.pasteNext]) { [unowned self] in pasteNext() }
        stackRelay = StackRelay { reps in Paster.write(reps, plainText: false, fallbackText: nil, to: .general) }
        stackTap = StackTap(onCommandV: { [stackRelay] in stackRelay?.commandV() }, onPasted: { [unowned self] in stackPasted() })
        stackPanel = StackPanelController(theme: theme)
        stackPanel.model.onStop = { [unowned self] in if stack.isOn { toggleStack() } }
        stackPanel.model.onRemove = { [unowned self] id in
            let head = stack.items.first
            stack.remove(id)
            refreshStackClipboard(writeHead: stack.items.first != head)
            syncStack()
        }
        stackPanel.model.onMove = { [unowned self] from, to in
            let head = stack.items.first
            stack.move(fromOffsets: from, toOffset: to)
            refreshStackClipboard(writeHead: stack.items.first != head)
            syncStack()
        }
        installStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self.shelf.prewarm() } }
        shelf.onOpenSettings = { [unowned self] in openSettings() }
        if !UserDefaults.standard.bool(forKey: Pref.didSetUp) { openSetup() }
        runRetention()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runRetention() }
        }
    }

    // MARK: paste stack

    /// On: copies collect in order and ⌘V pastes them one by one (the next is put on the clipboard after each ⌘V).
    func toggleStack() {
        if stack.isOn {
            stack.stop()
            stackTap.stop()
            Toast.show("Paste stack off")
        } else {
            stack.start()
            _ = stackTap.start()
        }
        syncStack()
    }

    /// Loads the stacked items' bytes on the store queue, then (main thread) puts the first on the clipboard and hands
    /// the rest to the relay, which switches the clipboard after each ⌘V.
    private func refreshStackClipboard(writeHead: Bool) {
        let ids = stack.items
        storeQueue.async { [store] in
            let reps = ids.map { (try? store?.representations($0)) ?? [] }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.stack.items == ids else { return }   // changed again meanwhile; a newer refresh follows
                    if writeHead, let head = reps.first { self.ownChangeCount = Paster.write(head, plainText: false, fallbackText: nil, to: .general) }
                    self.stackRelay.setUpcoming(Array(reps.dropFirst()))
                }
            }
        }
    }

    /// After a ⌘V (main thread): the pasted item leaves the stack, and the next goes on the clipboard a moment later,
    /// once the app has read it, unless another ⌘V already made the relay switch.
    private func stackPasted() {
        guard stack.isOn, let used = stack.next() else { return }
        storeQueue.async { [store] in try? store?.markUsed(used, now: Date()) }
        pendingFlush?.cancel()
        let flush = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stackRelay.flush()
                if !self.stack.isOn {
                    self.stackTap.stop()
                    Toast.show("Paste stack done")
                }
            }
        }
        pendingFlush = flush
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: flush)
        syncStack()
    }

    /// The optional shortcut: pastes the next stacked item without pressing ⌘V yourself.
    func pasteNext() {
        guard stack.isOn, !stack.items.isEmpty else {
            Toast.show(stack.isOn ? "The paste stack is empty: copy something first" : "The paste stack is off")
            return
        }
        stackRelay.commandV()
        Task { @MainActor in
            let result = await Paster.pressPaste(into: nil, autoPaste: UserDefaults.standard.bool(forKey: Pref.autoPaste))
            if result == .copiedOnly { Toast.show("Copied. Press ⌘V to paste.") }
            stackPasted()
        }
    }

    /// Applies changed shortcuts; false (and nothing changed) when another app already owns a global one.
    func setShortcut(_ action: ShortcutAction, _ combo: KeyCombo?) -> Bool {
        if action.isGlobal, let hotkey = globalHotkeys[action], !hotkey.update(combo) { return false }
        shortcuts[action] = combo
        shortcuts.save()
        shelf.shortcuts = shortcuts
        return true
    }

    func syncStack() {
        model.setStack(on: stack.isOn, ids: stack.items)
        shelf.relayout()
        guard stack.isOn else { stackPanel.hide(); return }
        let ids = stack.items, presses = stackTap.isRunning
        storeQueue.async { [store] in
            let items = ids.compactMap { try? store?.item($0) }
            DispatchQueue.main.async { MainActor.assumeIsolated { if self.stack.isOn { self.stackPanel.show(items, pressesForYou: presses) } } }
        }
    }

    func runRetention() {
        let maxAge = historyMaxAge(.standard)
        storeQueue.async { [store] in _ = try? store?.applyRetention(maxAge: maxAge, now: Date()) }
    }

    // MARK: menu bar

    /// Opening Mneme again (Finder, Spotlight) while it runs shows Settings: the way back when the menu bar icon is off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applyMenuBar() {
        if UserDefaults.standard.bool(forKey: Pref.showMenuBar) {
            if statusItem == nil { installStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: settings and setup

    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private lazy var settingsModel = SettingsModel(app: self)

    func openSettings(tab: String = "general") {
        if settingsWindow == nil {
            let view = SettingsView(settings: settingsModel, tab: tab).environmentObject(theme)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Mneme Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view)
            w.center()
            settingsWindow = w
        }
        settingsModel.refreshPermissions()
        settingsModel.reloadPinboards()
        guard !LaunchOptions.current.offscreen else { return }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func openSetup() {
        let view = SetupView(settings: settingsModel) { [unowned self] in
            UserDefaults.standard.set(true, forKey: Pref.didSetUp)
            setupWindow?.close()
            setupWindow = nil
        }.environmentObject(theme)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Set up Mneme"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.center()
        setupWindow = w
        guard !LaunchOptions.current.offscreen else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// While a shortcut is being recorded, the global ones are off so pressing them records instead of acting.
    func suspendHotkeys(_ on: Bool) {
        for (action, hotkey) in globalHotkeys { _ = hotkey.update(on ? nil : shortcuts[action]) }
    }

    @objc func openSettingsFromMenu() { openSettings() }

    private func runWindowSnapshot(to out: String) {
        let o = LaunchOptions.current
        if let n = o.stackPanel {
            let items = storeQueue.sync { [store] in (try? store!.page(Query(), offset: 0, limit: n)) ?? [] }
            stackPanel = StackPanelController(theme: theme)
            stackPanel.show(items, pressesForYou: true)
            let window = NSApp.windows.first { $0 is NSPanel && $0.isVisible }!
            window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated { Snapshot.write(window, to: out); NSApp.terminate(nil) }
            }
            return
        }
        if o.setup { openSetup() } else { openSettings(tab: o.settingsTab ?? "general") }
        let window = (o.setup ? setupWindow : settingsWindow)!
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated {
                Snapshot.write(window, to: out)
                NSApp.terminate(nil)
            }
        }
    }

    private func installStatusItem() {
        guard UserDefaults.standard.bool(forKey: Pref.showMenuBar) else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.make()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: shortcuts[.openShelf].map { "Open Mneme (\($0.display))" } ?? "Open Mneme", action: #selector(openShelf), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        if !model.captureAllowed {
            let off = NSMenuItem(title: "Capture is off: allow Mneme in Paste from Other Apps", action: #selector(openPasteSettings), keyEquivalent: "")
            off.target = self
            menu.addItem(off)
        }
        let stackItem = NSMenuItem(title: stack.isOn ? "Stop Paste Stack" : "Start Paste Stack" + (shortcuts[.toggleStack].map { " (\($0.display))" } ?? ""),
                                   action: #selector(toggleStackFromMenu), keyEquivalent: "")
        stackItem.target = self
        menu.addItem(stackItem)
        let pause = NSMenuItem(title: "Pause Capture", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = paused ? .on : .off
        menu.addItem(pause)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Mneme", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func openShelf() { DispatchQueue.main.async { MainActor.assumeIsolated { self.shelf.show() } } }
    @objc func togglePause() { paused.toggle() }
    @objc func toggleStackFromMenu() { toggleStack() }
    @objc func openPasteSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!)
    }

    // MARK: test runs

    private func applyLaunchFilters() {
        let o = LaunchOptions.current
        if let s = o.search { model.searchText = s }
        if let k = o.kind { model.kinds = k == .text ? [.text, .richText] : [k] }
    }

    private func runSnapshot(to out: String) {
        let o = LaunchOptions.current
        shelf.show { [unowned self] in
            if let name = o.pinboard, let board = model.pinboards.first(where: { $0.name == name }) { model.pinboard = board.id }
            applyLaunchFilters()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated {
                    self.model.selection = min(o.select, max(self.model.items.count - 1, 0))
                    if o.stack > 0 {
                        self.model.setStack(on: true, ids: self.model.items.prefix(o.stack).map(\.id))
                        self.shelf.relayout()
                    }
                    if let item = self.model.selectedItem {
                        switch o.overlay {
                        case "preview": self.model.overlay = .preview(item)
                        case "edit": self.model.overlay = .preview(item); self.model.editing = true
                        case "rename": self.model.overlay = .rename(item)
                        case "newboard": self.model.overlay = .newPinboard(pinning: item)
                        case "delete": self.model.overlay = .confirmDelete(item, pinboards: 2)
                        default: break
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        MainActor.assumeIsolated {
                            Snapshot.write(self.shelf.window, to: out)
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    /// Moves the selection one card at a time and times each update until it is drawn (a frame is 16.7 ms).
    private func runScroll(steps: Int) {
        shelf.prewarm { [unowned self] in
            shelf.show { [unowned self] in
                var times: [Double] = []
                // Back and forth: 40 cards right, 40 left, repeated, like a person looking for something.
                @MainActor func step(_ n: Int) {
                    guard n < steps else {
                        let sorted = times.sorted()
                        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
                        let slow = times.filter { $0 > 16.7 }.count
                        print(String(format: "scroll %d cards: median %.1f ms, p95 %.1f ms, max %.1f ms, %d over one frame", times.count, pct(0.5), pct(0.95), sorted.last ?? 0, slow))
                        fflush(stdout)
                        NSApp.terminate(nil)
                        return
                    }
                    let start = CACurrentMediaTime()
                    model.moveSelection(by: (n / 40) % 2 == 0 ? 1 : -1)
                    shelf.window.contentView?.layoutSubtreeIfNeeded()
                    shelf.window.displayIfNeeded()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.shelf.window.displayIfNeeded()
                            times.append((CACurrentMediaTime() - start) * 1000)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { MainActor.assumeIsolated { step(n + 1) } }
                        }
                    }
                }
                step(0)
            }
        }
    }

    private func runMeasure(cycles: Int) {
        var times: [Double] = []
        func cycle(_ n: Int) {
            guard n < cycles else {
                let sorted = times.sorted()
                let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
                print(String(format: "first frame: median %.1f ms, max %.1f ms over %d opens after warm-up; pid %d idle", median, sorted.last ?? 0, times.count, getpid()))
                fflush(stdout)
                return
            }
            let start = CACurrentMediaTime()
            shelf.show { [unowned self] in
                times.append((CACurrentMediaTime() - start) * 1000)
                shelf.hide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated { cycle(n + 1) } }
            }
        }
        let start = CACurrentMediaTime()
        shelf.prewarm {
            print(String(format: "warm-up (first build after launch): %.1f ms", (CACurrentMediaTime() - start) * 1000))
            cycle(0)
        }
    }
}

@main
struct MnemeMain {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--read-text" { TextReader.run() }
        // Maintenance: `--login-item on|off` sets whether this copy of Mneme opens at login, then quits.
        if CommandLine.arguments.dropFirst().first == "--login-item" {
            let on = CommandLine.arguments.dropFirst(2).first == "on"
            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { FileHandle.standardError.write("login item: \(error)\n".data(using: .utf8)!) }
            print("open at login for \(Bundle.main.bundlePath): \(SMAppService.mainApp.status == .enabled)")
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
