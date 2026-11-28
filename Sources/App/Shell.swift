import AppKit
import SwiftUI

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
