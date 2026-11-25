import AppKit
import SwiftUI

// MARK: glass

/// Apple's Liquid Glass on macOS 26; the standard translucent material before it.
extension View {
    @ViewBuilder func glassPanel(cornerRadius: CGFloat = 22) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder func glassSurface<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder func glassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { .regular.tint($0).interactive() } ?? .regular.interactive(), in: Capsule())
        } else {
            self.background(tint.map { AnyShapeStyle($0.opacity(0.35)) } ?? AnyShapeStyle(.thinMaterial), in: Capsule())
        }
    }
}

extension Color {
    /// #RRGGBB or #RRGGBBAA; grey when unreadable.
    init(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard let v = UInt64(h, radix: 16), h.count == 6 || h.count == 8 else { self = .gray; return }
        let rgba = h.count == 6 ? (v << 8) | 0xFF : v
        self = Color(.sRGB, red: Double(rgba >> 24 & 0xFF) / 255, green: Double(rgba >> 16 & 0xFF) / 255,
                     blue: Double(rgba >> 8 & 0xFF) / 255, opacity: Double(rgba & 0xFF) / 255)
    }
}
