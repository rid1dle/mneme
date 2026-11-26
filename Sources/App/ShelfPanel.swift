import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Opens, closes and drives the shelf. The SwiftUI tree exists only while the shelf is open.
@MainActor
final class ShelfController: NSObject, NSWindowDelegate {
    let model: ShelfModel
    let theme: ThemeStore
    let paster: Paster
    var offscreen = false
    var onOwnWrite: (Int) -> Void = { _ in }
    var onEditImage: (Item) -> Void = { _ in }
    var onStopStack: () -> Void = {}
    var shortcuts = Shortcuts.load()
    var onOpenSettings: () -> Void = {}
    private let panel = ShelfPanel()
    private var keyMonitor: Any?
    private var closeObservers: [NSObjectProtocol] = []
    private var deleteGuard = DeleteKeyGuard()
    private(set) var previousApp: NSRunningApplication?
    private(set) var isOpen = false

    init(model: ShelfModel, theme: ThemeStore, paster: Paster) {
        self.model = model
        self.theme = theme
        self.paster = paster
        super.init()
        panel.delegate = self
        model.perform = { [weak self] command in
            guard let self else { return }
            switch command {
            case .paste(let item, let plain): paste(item, plainText: plain)
            case .copy(let item): copy(item)
            case .editImage(let item): hide(); onEditImage(item)
            case .stopStack: onStopStack()
            case .openSettings: hide(); onOpenSettings()
            }
        }
    }

    /// Height changes when the paste stack strip appears or goes.
    func relayout() {
        guard isOpen else { return }
        panel.setFrame(frame(), display: true, animate: !offscreen)
    }

    var window: NSWindow { panel }

    func toggle() { isOpen ? hide() : show() }

    /// `ready` runs once the first page is loaded and drawn.
    func show(ready: (() -> Void)? = nil) {
        if isOpen { ready?(); return }
        isOpen = true
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previousApp : front
        let host = NSHostingView(rootView: ShelfView(model: model) { [weak self] item, plain in self?.paste(item, plainText: plain) }
            .environmentObject(theme))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(frame(), display: false)
        installKeyMonitor()
        model.reload { [weak self] in
            guard let self, isOpen else { return }
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            ready?()
        }
        panel.prepare(offscreen: offscreen)
        if offscreen {
            panel.orderFrontRegardless()
        } else {
            watchForLeaving()
            let target = panel.frame
            panel.setFrame(target.offsetBy(dx: 0, dy: -24), display: false)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Builds the shelf once off screen and throws it away, so the first real open does not pay for SwiftUI's
    /// first-time setup (about 600 ms on the 10,000-item store).
    func prewarm(done: (() -> Void)? = nil) {
        guard !isOpen else { return }
        let wasOffscreen = offscreen
        offscreen = true
        show { [weak self] in
            self?.hide()
            self?.offscreen = wasOffscreen
            done?()
        }
    }

    func hide() {
        guard isOpen else { return }
        isOpen = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for o in closeObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        closeObservers = []
        panel.orderOut(nil)
        panel.contentView = nil
        model.releaseCaches()
    }

    /// Besides losing focus, the shelf closes when another app comes to the front or the user switches Space, so it
    /// can never be left open over other work.
    private func watchForLeaving() {
        let center = NSWorkspace.shared.notificationCenter
        let me = ProcessInfo.processInfo.processIdentifier
        closeObservers = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.processIdentifier != me else { return }
                MainActor.assumeIsolated { self?.hide() }
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            },
        ]
    }

    func windowDidResignKey(_ notification: Notification) {
        if !offscreen { hide() }
    }

    /// Nearly the full width of the screen the pointer is on, floating just above its bottom edge (over the Dock).
    private func frame() -> NSRect {
        let height = theme.cardSize.height + 84 + (model.stackOn ? 38 : 0)
        if offscreen {
            let width = LaunchOptions.current.shelfWidth ?? 1280
            return NSRect(x: -30_000, y: -30_000, width: width, height: height)
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let f = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let inset: CGFloat = 8
        return NSRect(x: f.minX + inset, y: f.minY + inset, width: f.width - inset * 2, height: height)
    }

    // MARK: keys

    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === panel else { return event }
            return handle(event) ? nil : event
        }
    }

    private static let digitKeys: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// True when the shelf used the key; anything else goes on to the search field (or the open sheet or editor).
    func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        let key = Int(event.keyCode)
        let searchEmpty = model.searchText.isEmpty

        switch model.overlay {
        case .rename, .newPinboard, .confirmDelete:
            if key == kVK_Escape { model.overlay = nil; return true }
            return false
        case .preview(let item):
            if model.editing {
                if key == kVK_Escape { model.editing = false; return true }
                return false
            }
            switch key {
            case kVK_Escape: model.overlay = nil; return true
            case kVK_LeftArrow, kVK_RightArrow:
                model.moveSelection(by: key == kVK_LeftArrow ? -1 : 1)
                if let s = model.selectedItem { model.overlay = .preview(s) }
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter: paste(item, plainText: mods.contains(.shift)); return true
            default:
                let combo = KeyCombo(keyCode: UInt32(key), modifiers: carbonModifiers(mods))
                switch shortcuts.action(for: combo, shelf: true) {
                case .preview: model.overlay = nil
                case .edit:
                    if item.kind == .image { hide(); onEditImage(item) } else if item.kind == .text || item.kind == .richText { model.editing = true }
                case .copy: copy(item)
                case .pastePlain: paste(item, plainText: true)
                default: return false
                }
                return true
            }
        case nil:
            break
        }

        if searchFieldOwns(KeyCombo(keyCode: UInt32(key), modifiers: carbonModifiers(mods)), searchEmpty: searchEmpty) { return false }

        // Keys the shelf needs to move and paste (not changeable).
        switch key {
        case kVK_Escape:
            if !searchEmpty { model.searchText = "" } else { hide() }
            return true
        case kVK_LeftArrow where mods.isEmpty:
            model.moveSelection(by: -1); return true
        case kVK_RightArrow where mods.isEmpty:
            model.moveSelection(by: 1); return true
        case kVK_Return where mods.isEmpty, kVK_ANSI_KeypadEnter where mods.isEmpty:
            if let item = model.selectedItem { paste(item, plainText: false) }
            return true
        default:
            break
        }
        if mods == .command, let n = Self.digitKeys.firstIndex(of: key) {
            if model.items.indices.contains(n) { paste(model.items[n], plainText: false) }
            return true
        }

        // The user's shortcuts. One without ⌘, ⌃ or ⌥ (Space, ⌫) types into the search while it has text.
        let combo = KeyCombo(keyCode: UInt32(key), modifiers: carbonModifiers(mods))
        guard let action = shortcuts.action(for: combo, shelf: true) else { return false }
        if combo.modifiers & UInt32(cmdKey | controlKey | optionKey) == 0 && !searchEmpty && action != .pastePlain { return false }
        guard let item = model.selectedItem else { return action != .newPinboard }
        switch action {
        case .preview: model.overlay = .preview(item)
        case .edit:
            if item.kind == .image { hide(); onEditImage(item) }
            else if item.kind == .text || item.kind == .richText { model.overlay = .preview(item); model.editing = true }
        case .copy: copy(item)
        case .pastePlain: paste(item, plainText: true)
        case .rename: model.overlay = .rename(item)
        case .newPinboard: model.overlay = .newPinboard(pinning: item)
        case .remove:
            if deleteGuard.allows(isRepeat: event.isARepeat, searchEmpty: searchEmpty) { model.removeFromCurrent(item) }
        case .deleteEverywhere:
            if deleteGuard.allows(isRepeat: event.isARepeat, searchEmpty: searchEmpty) { model.deleteEverywhere(item) }
        case .openShelf, .toggleStack, .pasteNext: return false
        }
        return true
    }

    func copy(_ item: Item) {
        hide()
        put(item, plainText: false) { _ in
            Chimes.shared.play(.copy)
            Toast.show("Copied")
        }
    }

    /// Loads the item on the store queue, then writes it to the clipboard on the main thread: the main thread never
    /// waits for the store.
    private func put(_ item: Item, plainText: Bool, then: @escaping (Int) -> Void) {
        let id = item.id
        model.storeQueue.async { [store = model.store] in
            let reps = (try? store.representations(id)) ?? []
            let text = (try? store.item(id))??.text
            try? store.markUsed(id, now: Date())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !reps.isEmpty || text != nil else { Toast.show("Could not copy this item"); return }
                    let count = Paster.write(reps, plainText: plainText, fallbackText: text, to: .general)
                    self.onOwnWrite(count)
                    then(count)
                }
            }
        }
    }

    // MARK: paste

    func paste(_ item: Item, plainText: Bool) {
        let target = previousApp
        hide()
        put(item, plainText: plainText) { _ in
            Task { @MainActor in
                let result = await Paster.pressPaste(into: target, autoPaste: UserDefaults.standard.bool(forKey: Pref.autoPaste))
                Chimes.shared.play(result == .pasted ? .paste : .copy)
                if result == .copiedOnly { Toast.show("Copied. Press ⌘V to paste.") }
            }
        }
    }
}
