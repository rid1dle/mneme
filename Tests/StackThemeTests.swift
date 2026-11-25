import Foundation

private func defaults() -> UserDefaults {
    let name = "mneme-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

let stackThemeTests: [TestCase] = [
    test("should paste stacked copies in the order they were copied") {
        var s = PasteStack()
        let (a, b, c) = (UUID(), UUID(), UUID())
        s.start()
        s.add(a); s.add(b); s.add(c)
        expectEqual(s.remaining, 3)
        expectEqual(s.next(), a)
        expectEqual(s.next(), b)
        expectEqual(s.remaining, 1)
    },
    test("should ignore copies made while the stack is off") {
        var s = PasteStack()
        s.add(UUID())
        expectEqual(s.remaining, 0)
        expectEqual(s.next(), nil)
    },
    test("should move a repeated copy to the end of the stack") {
        var s = PasteStack()
        let (a, b) = (UUID(), UUID())
        s.start()
        s.add(a); s.add(b); s.add(a)
        expectEqual(s.items, [b, a])
    },
    test("should turn the stack off once the last item is pasted") {
        var s = PasteStack()
        let a = UUID()
        s.start()
        s.add(a)
        expectEqual(s.next(), a)
        expectEqual(s.isOn, false)
        s.add(UUID())
        expectEqual(s.remaining, 0)
    },
    test("should start empty each time the stack is turned on") {
        var s = PasteStack()
        s.start(); s.add(UUID()); s.stop()
        expectEqual(s.remaining, 0)
        s.start()
        expectEqual(s.remaining, 0)
        expect(s.isOn)
    },
    test("should drop an item the user removes from the stack and stay on") {
        var s = PasteStack()
        let (a, b) = (UUID(), UUID())
        s.start(); s.add(a); s.add(b)
        s.remove(a)
        expectEqual(s.items, [b])
        s.remove(b)
        expectEqual(s.items, [])
        expect(s.isOn)
    },
    test("should move a stacked item to a new place in the order") {
        var s = PasteStack()
        let (a, b, c) = (UUID(), UUID(), UUID())
        s.start(); s.add(a); s.add(b); s.add(c)
        s.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        expectEqual(s.items, [c, a, b])
        s.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        expectEqual(s.items, [a, b, c])
    },
    test("should start with the first preset when nothing is saved") {
        expectEqual(loadTheme(defaults()), themePresets[0].theme)
        expectEqual(themePresets[0].theme.appearance, .system)
        expectEqual(themePresets[0].theme.shelf, .glass)
        expectEqual(themePresets[0].theme.cardSize, .medium)
    },
    test("should read back a saved theme") {
        let d = defaults()
        let t = Theme(appearance: .dark, accent: "#BF5AF2", shelf: .solid, cardSize: .large)
        saveTheme(t, d)
        expectEqual(loadTheme(d), t)
    },
    test("should fall back to the default when the saved theme is unreadable") {
        let d = defaults()
        d.set(Data("not json".utf8), forKey: "theme")
        expectEqual(loadTheme(d), themePresets[0].theme)
    },
    test("should give every preset a valid accent color") {
        expectEqual(themePresets.count, 4)
        for p in themePresets { expectEqual(parseColor(p.theme.accent), p.theme.accent, p.name) }
        expectEqual(Set(themePresets.map(\.name)).count, 4)
    },
]
