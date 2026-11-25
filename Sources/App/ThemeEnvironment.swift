import AppKit
import SwiftUI

/// The one source of the current theme; every view reads it from the environment.
@MainActor
final class ThemeStore: ObservableObject {
    @Published var theme: Theme { didSet { saveTheme(theme, defaults); apply() } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = loadTheme(defaults)
    }

    var accent: Color { Color(hex: theme.accent) }

    var colorScheme: ColorScheme? {
        switch theme.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch theme.appearance {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    func apply() { NSApp.appearance = nsAppearance }

    var cardSize: CGSize {
        switch theme.cardSize {
        case .small: return CGSize(width: 200, height: 220)
        case .medium: return CGSize(width: 240, height: 262)
        case .large: return CGSize(width: 280, height: 306)
        }
    }
}
