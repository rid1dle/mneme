import Foundation

public enum Appearance: String, CaseIterable, Codable { case system, light, dark }
public enum ShelfStyle: String, CaseIterable, Codable { case glass, solid }
public enum CardSize: String, CaseIterable, Codable { case small, medium, large }

public struct Theme: Codable, Equatable {
    public var appearance: Appearance
    /// #RRGGBB
    public var accent: String
    public var shelf: ShelfStyle
    public var cardSize: CardSize
    public init(appearance: Appearance, accent: String, shelf: ShelfStyle, cardSize: CardSize) {
        self.appearance = appearance; self.accent = accent; self.shelf = shelf; self.cardSize = cardSize
    }
}

public struct ThemePreset: Equatable {
    public let name: String
    public let theme: Theme
}

/// The first preset is the default.
public let themePresets: [ThemePreset] = [
    ThemePreset(name: "Default", theme: Theme(appearance: .system, accent: "#0A84FF", shelf: .glass, cardSize: .medium)),
    ThemePreset(name: "Graphite", theme: Theme(appearance: .dark, accent: "#8E8E93", shelf: .solid, cardSize: .medium)),
    ThemePreset(name: "Paper", theme: Theme(appearance: .light, accent: "#FF9F0A", shelf: .solid, cardSize: .medium)),
    ThemePreset(name: "Midnight", theme: Theme(appearance: .dark, accent: "#BF5AF2", shelf: .glass, cardSize: .medium)),
]

let themeKey = "theme"

public func loadTheme(_ d: UserDefaults) -> Theme {
    d.data(forKey: themeKey).flatMap { try? JSONDecoder().decode(Theme.self, from: $0) } ?? themePresets[0].theme
}

public func saveTheme(_ t: Theme, _ d: UserDefaults) {
    if let data = try? JSONEncoder().encode(t) { d.set(data, forKey: themeKey) }
}
