import AppKit
import SwiftUI

/// A short message near the bottom of the screen ("Copied, press ⌘V"), gone after a moment.
@MainActor
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String, seconds: Double = 1.6) {
        panel?.orderOut(nil)
        let view = NSHostingView(rootView:
            Text(text).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16).padding(.vertical, 9)
                .glassCapsule()
                .padding(8))
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        let p = NSPanel(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.minY + 40, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = view
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                if panel === p { p.orderOut(nil); panel = nil }
            }
        }
    }
}
