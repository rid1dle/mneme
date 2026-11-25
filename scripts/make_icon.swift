// Draws the Mneme app icon and writes build/AppIcon.iconset (then: iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns).
//   swiftc -O -o build/make_icon scripts/make_icon.swift && build/make_icon
// Mneme means memory: a fan of glass cards (what was copied), the front one lit.
import AppKit
import SwiftUI

let teal = Color(red: 0.10, green: 0.62, blue: 0.66)
let deep = Color(red: 0.03, green: 0.13, blue: 0.20)
let amber = Color(red: 1.0, green: 0.72, blue: 0.30)

struct Icon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.06, green: 0.32, blue: 0.38), deep], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 14)

            Circle()
                .fill(RadialGradient(colors: [teal.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 340))
                .frame(width: 680, height: 680)
                .offset(y: 30)

            Card(lit: false).rotationEffect(.degrees(-16)).offset(x: -92, y: 24)
            Card(lit: false).rotationEffect(.degrees(-5)).offset(x: -30, y: 4)
            Card(lit: true).rotationEffect(.degrees(7)).offset(x: 48, y: -14)
        }
        .frame(width: 1024, height: 1024)
    }
}

struct Card: View {
    var lit: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 46, style: .continuous)
                .fill(LinearGradient(colors: lit ? [.white.opacity(0.34), .white.opacity(0.14)] : [.white.opacity(0.16), .white.opacity(0.06)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 46, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(lit ? 0.85 : 0.45), .white.opacity(0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 5)
            if lit {
                VStack(alignment: .leading, spacing: 26) {
                    Capsule().fill(amber).frame(width: 120, height: 26)
                    Capsule().fill(.white.opacity(0.85)).frame(width: 230, height: 20)
                    Capsule().fill(.white.opacity(0.65)).frame(width: 190, height: 20)
                    Capsule().fill(.white.opacity(0.45)).frame(width: 210, height: 20)
                }
                .padding(52)
            }
        }
        .frame(width: 330, height: 430)
        .shadow(color: .black.opacity(0.30), radius: 20, y: 12)
    }
}

@MainActor func png(size: Int) -> Data? {
    let renderer = ImageRenderer(content: Icon().frame(width: 1024, height: 1024))
    renderer.scale = CGFloat(size) / 1024
    guard let cg = renderer.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
}

MainActor.assumeIsolated {
    let fm = FileManager.default
    let set = "build/AppIcon.iconset"
    try? fm.removeItem(atPath: set)
    try! fm.createDirectory(atPath: set, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try! png(size: base * scale)!.write(to: URL(fileURLWithPath: "\(set)/\(name)"))
        }
    }
    try! png(size: 1024)!.write(to: URL(fileURLWithPath: "build/AppIcon-1024.png"))
    print("wrote \(set)")
}
