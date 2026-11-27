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
    var formatter: PasteFormatter?
    private let panel = ShelfPanel()
    private var keyMonitor: Any?
    private var closeObservers: [NSObjectProtocol] = []
    private var deleteGuard = DeleteKeyGuard()
    private(set) var previousApp: NSRunningApplication?
    private(set) var isOpen = false
    /// Bumped on every open and close, so a close animation that finishes after the shelf reopened does nothing.
    private var generation = 0

    init(model: ShelfModel, theme: ThemeStore, paster: Paster) {
        self.model = model
        self.theme = theme
        self.paster = paster
        super.init()
        panel.delegate = self
        model.perform = { [weak self] command in
            guard let self else { return }
            switch command {
            case .paste(let item, let plain): paste(item, as: plain ? .plain : nil)
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

    func toggle() { isOpen ? hide(animated: true) : show() }

    /// `ready` runs once the first page is loaded and drawn.
    func show(ready: (() -> Void)? = nil) {
        if isOpen { ready?(); return }
        isOpen = true
        generation += 1
        let gen = generation
        panel.ignoresMouseEvents = false
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previousApp : front
        let host = NSHostingView(rootView: ShelfView(model: model) { [weak self] item, plain in self?.paste(item, as: plain ? .plain : nil) }
            .padding(ShelfPanel.margin)
            .environmentObject(theme))
        host.sizingOptions = []
        host.wantsLayer = true
        panel.contentView = host
        panel.setFrame(frame(), display: false)
        installKeyMonitor()
        model.reload { [weak self] in
            guard let self, isOpen else { return }
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            reveal(gen)
            ready?()
        }
        panel.prepare(offscreen: offscreen)
        if offscreen {
            panel.orderFrontRegardless()
        } else {
            watchForLeaving()
            // Invisible but already taking keys until the first page is drawn, then it rises in (see reveal).
            host.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.reveal(gen) }
        }
    }

    /// Brings the drawn shelf in with the chosen style. Core Animation runs it outside the main thread, so building
    /// cards and loading thumbnails cannot make it stutter.
    private func reveal(_ gen: Int) {
        guard !offscreen, gen == generation, isOpen, let host = panel.contentView, host.alphaValue == 0, let layer = host.layer else { return }
        play(motion.open, opening: true, on: layer, before: { host.alphaValue = 1 })
    }

    private var motion: ShelfMotion { ShelfMotion(saved: UserDefaults.standard.string(forKey: Pref.shelfMotion)) }

    /// Presentation-only animations between the move's hidden pose and rest. A closing one holds its last frame
    /// until the window is ordered out.
    private func play(_ move: ShelfMove, opening: Bool, on layer: CALayer, before: () -> Void = {}, done: (() -> Void)? = nil) {
        let hidden = move.hidden(shelfHeight: layer.bounds.height - ShelfPanel.margin * 2)
        let (from, to) = opening ? (hidden, ShelfPose.rest) : (ShelfPose.rest, hidden)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let done { CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } } }
        before()
        var animations: [CABasicAnimation] = []
        if from.opacity != to.opacity {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = from.opacity
            a.toValue = to.opacity
            a.duration = move.fadeDuration
            a.timingFunction = timing(move.fadeCurve)
            animations.append(a)
        }
        if from.drop != to.drop || from.scale != to.scale {
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = NSValue(caTransform3D: transform(from, layer))
            a.toValue = NSValue(caTransform3D: transform(to, layer))
            a.duration = move.duration
            a.timingFunction = timing(move.curve)
            animations.append(a)
        }
        for a in animations {
            if !opening {
                a.fillMode = .forwards
                a.isRemovedOnCompletion = false
            }
            layer.add(a, forKey: "shelf.\(a.keyPath ?? "")")
        }
        CATransaction.commit()
    }

    private func timing(_ c: [Double]) -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]))
    }

    /// Scales about the middle of the shelf and moves it down by `drop` (the layer's y axis points up).
    private func transform(_ p: ShelfPose, _ layer: CALayer) -> CATransform3D {
        let cx = layer.bounds.width * (0.5 - layer.anchorPoint.x), cy = layer.bounds.height * (0.5 - layer.anchorPoint.y)
        var t = CATransform3DMakeTranslation(cx, cy - p.drop, 0)
        t = CATransform3DScale(t, p.scale, p.scale, 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
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

    /// `animated` only when nothing waits on the app underneath getting the keys back (Esc, clicking away): a paste
    /// closes at once, so its ⌘V reaches that app and not the fading shelf.
    func hide(animated: Bool = false) {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        let gen = generation
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for o in closeObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        closeObservers = []
        guard animated, !offscreen, let layer = panel.contentView?.layer else { finishHide(); return }
        panel.makeFirstResponder(nil)
        panel.ignoresMouseEvents = true
        play(motion.close, opening: false, on: layer, done: { [weak self] in
            if let self, self.generation == gen { self.finishHide() }
        })
    }

    private func finishHide() {
        panel.orderOut(nil)
        panel.contentView = nil
        panel.ignoresMouseEvents = false
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
                MainActor.assumeIsolated { self?.hide(animated: true) }
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide(animated: true) }
            },
        ]
    }

    func windowDidResignKey(_ notification: Notification) {
        if !offscreen { hide(animated: true) }
    }

    /// Nearly the full width of the screen the pointer is on, floating just above its bottom edge (over the Dock).
    private func frame() -> NSRect {
        let height = theme.cardSize.height + 84 + (model.stackOn ? 38 : 0)
        if offscreen {
            let width = LaunchOptions.current.shelfWidth ?? 1280
            return NSRect(x: -30_000, y: -30_000, width: width, height: height).insetBy(dx: -ShelfPanel.margin, dy: -ShelfPanel.margin)
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let f = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let inset: CGFloat = 8
        return NSRect(x: f.minX + inset, y: f.minY + inset, width: f.width - inset * 2, height: height)
            .insetBy(dx: -ShelfPanel.margin, dy: -ShelfPanel.margin)
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
            case kVK_Return, kVK_ANSI_KeypadEnter: paste(item, as: Self.chosenVersion(mods)); return true
            default:
                let combo = KeyCombo(keyCode: UInt32(key), modifiers: carbonModifiers(mods))
                switch shortcuts.action(for: combo, shelf: true) {
                case .preview: model.overlay = nil
                case .edit:
                    if item.kind == .image { hide(); onEditImage(item) } else if item.kind == .text || item.kind == .richText { model.editing = true }
                case .copy: copy(item)
                case .pastePlain: paste(item, as: .plain)
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
            if !searchEmpty { model.searchText = "" } else { hide(animated: true) }
            return true
        case kVK_LeftArrow where mods.isEmpty:
            model.moveSelection(by: -1); return true
        case kVK_RightArrow where mods.isEmpty:
            model.moveSelection(by: 1); return true
        case kVK_Return where mods.isEmpty || mods == .option, kVK_ANSI_KeypadEnter where mods.isEmpty || mods == .option:
            if let item = model.selectedItem { paste(item, as: Self.chosenVersion(mods)) }
            return true
        default:
            break
        }
        if mods == .command, let n = Self.digitKeys.firstIndex(of: key) {
            if model.items.indices.contains(n) { paste(model.items[n], as: nil) }
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
        case .pastePlain: paste(item, as: .plain)
        case .rename: model.overlay = .rename(item)
        case .newPinboard: model.overlay = .newPinboard(pinning: item)
        case .remove:
            if deleteGuard.allows(isRepeat: event.isARepeat, searchEmpty: searchEmpty) { model.removeFromCurrent(item) }
        case .deleteEverywhere:
            if deleteGuard.allows(isRepeat: event.isARepeat, searchEmpty: searchEmpty) { model.deleteEverywhere(item) }
        case .openShelf, .toggleStack, .pasteNext, .pastePlainNow, .pasteOriginalNow: return false
        }
        return true
    }

    func copy(_ item: Item) {
        hide()
        put(item, as: nil, target: nil) { _ in
            Chimes.shared.play(.copy)
            Toast.show("Copied")
        }
    }

    /// Loads the item on the store queue, then writes it to the clipboard on the main thread: the main thread never
    /// waits for the store.
    private func put(_ item: Item, as version: PasteVersion?, target: NSRunningApplication?, then: @escaping (Int) -> Void) {
        let id = item.id
        model.storeQueue.async { [store = model.store] in
            let reps = (try? store.representations(id)) ?? []
            let text = (try? store.item(id))??.text
            try? store.markUsed(id, now: Date())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !reps.isEmpty || text != nil else { Toast.show("Could not copy this item"); return }
                    let count = self.formatter?.put(reps, text: text, source: item.source, target: target, as: version)
                        ?? Paster.write(reps, plainText: version == .plain, fallbackText: text, to: .general)
                    self.onOwnWrite(count)
                    then(count)
                }
            }
        }
    }

    // MARK: paste

    static func chosenVersion(_ mods: NSEvent.ModifierFlags) -> PasteVersion? {
        mods.contains(.shift) ? .plain : mods.contains(.option) ? .original : nil
    }

    /// `version` nil: the form that suits the app it goes into (or as copied when that is switched off); ⇧↩ plain
    /// text, ⌥↩ the original.
    func paste(_ item: Item, as version: PasteVersion?) {
        let target = previousApp
        hide()
        put(item, as: version, target: target) { _ in
            Task { @MainActor in
                let result = await Paster.pressPaste(into: target, autoPaste: UserDefaults.standard.bool(forKey: Pref.autoPaste))
                Chimes.shared.play(result == .pasted ? .paste : .copy)
                if result == .copiedOnly { Toast.show("Copied. Press ⌘V to paste.") }
            }
        }
    }
}
