import AppKit
import Carbon.HIToolbox
import Foundation

private func defaults() -> UserDefaults {
    let name = "mneme-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}
private func combo(_ key: Int, _ mods: Int = 0) -> KeyCombo { KeyCombo(keyCode: UInt32(key), modifiers: UInt32(mods)) }

let shortcutTests: [TestCase] = [
    test("should start every action on its default shortcut") {
        let s = Shortcuts.load(defaults())
        expectEqual(s[.openShelf], combo(kVK_ANSI_V, cmdKey | shiftKey))
        expectEqual(s[.toggleStack], combo(kVK_ANSI_C, cmdKey | shiftKey))
        expectEqual(s[.pasteNext], nil)
        expectEqual(s[.preview], combo(kVK_Space))
        expectEqual(s[.remove], combo(kVK_Delete))
        expectEqual(s[.deleteEverywhere], combo(kVK_Delete, cmdKey))
    },
    test("should keep a changed and a cleared shortcut after saving") {
        let d = defaults()
        var s = Shortcuts.load(d)
        s[.openShelf] = combo(kVK_ANSI_B, cmdKey | optionKey)
        s[.edit] = nil
        s.save(d)
        let again = Shortcuts.load(d)
        expectEqual(again[.openShelf], combo(kVK_ANSI_B, cmdKey | optionKey))
        expectEqual(again[.edit], nil)
        expectEqual(again[.copy], combo(kVK_ANSI_C, cmdKey))
    },
    test("should refuse a global shortcut without command, control or option") {
        let s = Shortcuts.load(defaults())
        expectEqual(s.problem(combo(kVK_ANSI_V, shiftKey), for: .openShelf), .needsModifier)
        expectEqual(s.problem(combo(kVK_ANSI_V, controlKey | optionKey), for: .openShelf), nil)
    },
    test("should refuse a letter inside the shelf without a modifier because it types into search") {
        let s = Shortcuts.load(defaults())
        expectEqual(s.problem(combo(kVK_ANSI_P), for: .preview), .needsModifier)
        expectEqual(s.problem(combo(kVK_Space, shiftKey), for: .preview), nil)
    },
    test("should refuse a shortcut another action already uses and name it") {
        let s = Shortcuts.load(defaults())
        expectEqual(s.problem(combo(kVK_ANSI_C, cmdKey), for: .edit), .taken(by: .copy))
        expectEqual(s.problem(combo(kVK_ANSI_C, cmdKey), for: .copy), nil)
    },
    test("should refuse keys the shelf needs for moving and pasting") {
        let s = Shortcuts.load(defaults())
        for c in [combo(kVK_Return), combo(kVK_Escape), combo(kVK_LeftArrow), combo(kVK_ANSI_3, cmdKey)] {
            expectEqual(s.problem(c, for: .rename), .reserved)
        }
    },
    test("should find which action a key press belongs to") {
        let s = Shortcuts.load(defaults())
        expectEqual(s.action(for: combo(kVK_ANSI_E, cmdKey), shelf: true), .edit)
        expectEqual(s.action(for: combo(kVK_ANSI_E, cmdKey), shelf: false), nil)
        expectEqual(s.action(for: combo(kVK_ANSI_V, cmdKey | shiftKey), shelf: false), .openShelf)
    },
    test("should leave line and word deletion to the search field while it has text") {
        for m in [cmdKey, optionKey, controlKey, 0] {
            expect(searchFieldOwns(combo(kVK_Delete, m), searchEmpty: false), "modifiers \(m)")
            expect(searchFieldOwns(combo(kVK_ForwardDelete, m), searchEmpty: false))
        }
    },
    test("should leave select all, copy, cut, paste and undo to the search field while it has text") {
        for k in [kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_X, kVK_ANSI_V, kVK_ANSI_Z] { expect(searchFieldOwns(combo(k, cmdKey), searchEmpty: false)) }
        expect(searchFieldOwns(combo(kVK_ANSI_Z, cmdKey | shiftKey), searchEmpty: false))
        expect(searchFieldOwns(combo(kVK_LeftArrow, optionKey), searchEmpty: false))
    },
    test("should give the shelf its shortcuts back when the search is empty or the key is not for editing") {
        expect(!searchFieldOwns(combo(kVK_Delete, cmdKey), searchEmpty: true))
        expect(!searchFieldOwns(combo(kVK_ANSI_C, cmdKey), searchEmpty: true))
        expect(!searchFieldOwns(combo(kVK_ANSI_E, cmdKey), searchEmpty: false))
        expect(!searchFieldOwns(combo(kVK_Return, shiftKey), searchEmpty: false))
    },
    test("should turn AppKit modifier flags into Carbon ones") {
        expectEqual(carbonModifiers([.command, .shift]), UInt32(cmdKey | shiftKey))
        expectEqual(carbonModifiers([.control, .option, .capsLock, .function]), UInt32(controlKey | optionKey))
    },
    test("should step forward on Tab and back on shift Tab, and leave other keys alone") {
        let s = Shortcuts.load(defaults())
        expectEqual(boardStep(combo(kVK_Tab), shortcuts: s), 1)
        expectEqual(boardStep(combo(kVK_Tab, shiftKey), shortcuts: s), -1)
        expect(boardStep(combo(kVK_Tab, cmdKey), shortcuts: s) == nil, "⌘Tab is the app switcher")
        expect(boardStep(combo(kVK_Tab, optionKey), shortcuts: s) == nil)
        expect(boardStep(combo(kVK_RightArrow), shortcuts: s) == nil)
    },
    test("should leave Tab to a shortcut the user gave it") {
        var s = Shortcuts.load(defaults())
        s[.preview] = combo(kVK_Tab)
        expect(boardStep(combo(kVK_Tab), shortcuts: s) == nil)
        expectEqual(boardStep(combo(kVK_Tab, shiftKey), shortcuts: s), -1, "shift Tab still switches")
    },
    test("should cycle from History through each pinboard and wrap around both ways") {
        let a = UUID(), b = UUID()
        expectEqual(cycledBoard(from: nil, boards: [a, b], step: 1), a)
        expectEqual(cycledBoard(from: a, boards: [a, b], step: 1), b)
        expect(cycledBoard(from: b, boards: [a, b], step: 1) == nil, "after the last pinboard comes History")
        expectEqual(cycledBoard(from: nil, boards: [a, b], step: -1), b, "before History comes the last pinboard")
        expectEqual(cycledBoard(from: b, boards: [a, b], step: -1), a)
    },
    test("should stay on History when there are no pinboards, and start over from History when the pinboard is gone") {
        expect(cycledBoard(from: nil, boards: [], step: 1) == nil)
        expect(cycledBoard(from: nil, boards: [], step: -1) == nil)
        let a = UUID()
        expectEqual(cycledBoard(from: UUID(), boards: [a], step: 1), a)
    },
]
