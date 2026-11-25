import AppKit

/// The menu bar icon: three fanned cards like the app icon, drawn as a template so it follows the menu bar's colour.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            func card(_ rect: NSRect, angle: CGFloat, fill: Bool) {
                let t = NSAffineTransform()
                t.translateX(by: rect.midX, yBy: rect.midY)
                t.rotate(byDegrees: angle)
                t.translateX(by: -rect.midX, yBy: -rect.midY)
                let path = NSBezierPath(roundedRect: rect, xRadius: 2.2, yRadius: 2.2)
                path.transform(using: t as AffineTransform)
                path.lineWidth = 1.4
                if fill {
                    // The front card hides the back one.
                    NSGraphicsContext.current?.compositingOperation = .clear
                    path.fill()
                    NSGraphicsContext.current?.compositingOperation = .sourceOver
                }
                NSColor.black.setStroke()
                path.stroke()
                if fill {
                    NSColor.black.setFill()
                    let lines = NSBezierPath()
                    for (n, w) in [5.0, 5.0, 3.4].enumerated() {
                        lines.appendRect(NSRect(x: rect.minX + 2.0, y: rect.maxY - 3.8 - Double(n) * 2.5, width: w, height: 1.1))
                    }
                    lines.transform(using: t as AffineTransform)
                    lines.fill()
                }
            }
            card(NSRect(x: 2.2, y: 3.4, width: 9, height: 11.5), angle: 14, fill: false)
            card(NSRect(x: 6.6, y: 2.6, width: 9, height: 11.5), angle: -8, fill: true)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mneme"
        return image
    }
}
