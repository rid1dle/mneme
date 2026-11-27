import AppKit

/// The borderless panel the shelf lives in: takes keys without activating Mneme, so the app the user was in stays
/// frontmost underneath; shows on every space and over full-screen apps.
/// The shelf draws its own shadow inside a clear margin: the system's window shadow came out square around the
/// rounded shelf on screen, and the margin also gives the open and close slide room to move.
final class ShelfPanel: NSPanel {
    static let margin: CGFloat = 24

    /// Off-screen drawings (tests, the warm-up after launch) must never take keyboard focus from the app the user is
    /// typing in; the real shelf must always be able to. Set on every open.
    private(set) var neverKey = false

    func prepare(offscreen: Bool) { neverKey = offscreen }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { !neverKey }
    override var canBecomeMain: Bool { false }
}

