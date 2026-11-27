import AppKit
import Carbon.HIToolbox

/// Everything that has a shortcut. Global ones work in any app; the rest work while the shelf is open.
enum ShortcutAction: String, CaseIterable, Codable {
    case openShelf, toggleStack, pasteNext, pastePlainNow, pasteOriginalNow
    case preview, edit, copy, pastePlain, rename, newPinboard, remove, deleteEverywhere

    var isGlobal: Bool { [.openShelf, .toggleStack, .pasteNext, .pastePlainNow, .pasteOriginalNow].contains(self) }

    var title: String {
        switch self {
        case .openShelf: return "Open Mneme"
        case .toggleStack: return "Paste stack on or off"
        case .pasteNext: return "Paste next from the stack"
        case .pastePlainNow: return "Paste as plain text in any app"
        case .pasteOriginalNow: return "Paste with original formatting in any app"
        case .preview: return "Preview"
        case .edit: return "Edit"
        case .copy: return "Copy without pasting"
        case .pastePlain: return "Paste as plain text"
        case .rename: return "Rename"
        case .newPinboard: return "New pinboard"
        case .remove: return "Remove from History or pinboard"
        case .deleteEverywhere: return "Delete everywhere"
        }
    }

    var note: String? {
        switch self {
        case .toggleStack: return "While it is on, copy items, then press ⌘V for each one in order."
        case .pasteNext: return "Optional: ⌘V already pastes the next one when Accessibility is allowed."
        case .pastePlainNow: return "What you copied, as text only. Mneme learns where you prefer this."
        case .pasteOriginalNow: return "What you copied, exactly as it was, colours and fonts included."
        default: return nil
        }
    }

    var defaultCombo: KeyCombo? {
        func c(_ k: Int, _ m: Int = 0) -> KeyCombo { KeyCombo(keyCode: UInt32(k), modifiers: UInt32(m)) }
        switch self {
        case .openShelf: return c(kVK_ANSI_V, cmdKey | shiftKey)
        case .toggleStack: return c(kVK_ANSI_C, cmdKey | shiftKey)
        case .pasteNext: return nil
        case .pastePlainNow: return c(kVK_ANSI_V, cmdKey | shiftKey | optionKey)
        case .pasteOriginalNow: return c(kVK_ANSI_V, cmdKey | controlKey | optionKey)
        case .preview: return c(kVK_Space)
        case .edit: return c(kVK_ANSI_E, cmdKey)
        case .copy: return c(kVK_ANSI_C, cmdKey)
        case .pastePlain: return c(kVK_Return, shiftKey)
        case .rename: return c(kVK_ANSI_R, cmdKey)
        case .newPinboard: return c(kVK_ANSI_N, cmdKey)
        case .remove: return c(kVK_Delete)
        case .deleteEverywhere: return c(kVK_Delete, cmdKey)
        }
    }
}

enum ShortcutProblem: Equatable {
    case needsModifier, reserved, taken(by: ShortcutAction)

    var message: String {
        switch self {
        case .needsModifier: return "Add ⌘, ⌃ or ⌥: a plain key would type instead"
        case .reserved: return "Mneme needs this key to move and paste"
        case .taken(let other): return "Already used for “\(other.title)”"
        }
    }
}

/// The user's shortcuts, saved as one JSON object (a cleared shortcut is saved as cleared, not reset).
struct Shortcuts: Equatable {
    private var map: [ShortcutAction: KeyCombo?] = [:]
    static let key = "shortcuts"

    static func load(_ d: UserDefaults = .standard) -> Shortcuts {
        var s = Shortcuts()
        let saved = d.data(forKey: key).flatMap { try? JSONDecoder().decode([String: KeyCombo?].self, from: $0) } ?? [:]
        for a in ShortcutAction.allCases { s.map[a] = saved.keys.contains(a.rawValue) ? saved[a.rawValue]! : a.defaultCombo }
        return s
    }

    func save(_ d: UserDefaults = .standard) {
        let out = Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(out) { d.set(data, forKey: Shortcuts.key) }
    }

    subscript(_ a: ShortcutAction) -> KeyCombo? {
        get { map[a] ?? a.defaultCombo }
        set { map[a] = .some(newValue) }
    }

    func action(for combo: KeyCombo, shelf: Bool) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0.isGlobal != shelf && self[$0] == combo }
    }

    private static let strong = UInt32(cmdKey | controlKey | optionKey)
    private static let bareAllowed: Set<Int> = [kVK_Space, kVK_Delete, kVK_ForwardDelete, kVK_Tab,
                                                kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
    private static let digits: Set<Int> = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// Why this combo cannot be used for this action, or nil when it can.
    func problem(_ c: KeyCombo, for a: ShortcutAction) -> ShortcutProblem? {
        let key = Int(c.keyCode)
        let hasStrong = c.modifiers & Shortcuts.strong != 0
        if !a.isGlobal {
            if (key == kVK_Return || key == kVK_ANSI_KeypadEnter) && c.modifiers == 0 { return .reserved }
            if [kVK_Escape, kVK_LeftArrow, kVK_RightArrow].contains(key) { return .reserved }
            if Shortcuts.digits.contains(key) && c.modifiers == UInt32(cmdKey) { return .reserved }
        }
        if a.isGlobal && !hasStrong { return .needsModifier }
        if !a.isGlobal && !hasStrong && !Shortcuts.bareAllowed.contains(key) && !(key == kVK_Return && c.modifiers != 0) { return .needsModifier }
        if let other = ShortcutAction.allCases.first(where: { $0 != a && self[$0] == c }) {
            return .taken(by: other)
        }
        return nil
    }
}

func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var m = 0
    if flags.contains(.command) { m |= cmdKey }
    if flags.contains(.shift) { m |= shiftKey }
    if flags.contains(.option) { m |= optionKey }
    if flags.contains(.control) { m |= controlKey }
    return UInt32(m)
}

extension KeyCombo {
    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers(event.modifierFlags))
    }
}

/// While the search field has text, the keys that edit text are the field's, not the shelf's: every ⌫ and
/// forward-delete variant, ⌘A/C/X/V/Z, and arrows with a modifier (word and line moves).
func searchFieldOwns(_ c: KeyCombo, searchEmpty: Bool) -> Bool {
    guard !searchEmpty else { return false }
    let key = Int(c.keyCode)
    if key == kVK_Delete || key == kVK_ForwardDelete { return true }
    if (key == kVK_LeftArrow || key == kVK_RightArrow) && c.modifiers != 0 { return true }
    let cmd = UInt32(cmdKey), cmdShift = UInt32(cmdKey | shiftKey)
    if c.modifiers == cmd && [kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_X, kVK_ANSI_V, kVK_ANSI_Z].contains(key) { return true }
    if c.modifiers == cmdShift && key == kVK_ANSI_Z { return true }
    return false
}

/// Tab moves the shelf to the next of History and the pinboards, ⇧Tab to the one before: 1, -1, or nil for any
/// other key and for a Tab the user gave to one of their shortcuts.
func boardStep(_ c: KeyCombo, shortcuts: Shortcuts) -> Int? {
    guard Int(c.keyCode) == kVK_Tab, shortcuts.action(for: c, shelf: true) == nil else { return nil }
    switch c.modifiers {
    case 0: return 1
    case UInt32(shiftKey): return -1
    default: return nil
    }
}

/// The board a step lands on: History (nil), then each pinboard in order, wrapping around at both ends.
func cycledBoard(from current: UUID?, boards: [UUID], step: Int) -> UUID? {
    let order: [UUID?] = [nil] + boards
    let at = order.firstIndex(of: current) ?? 0
    return order[((at + step) % order.count + order.count) % order.count]
}

/// ⌫ and ⌘⌫ remove cards only on a fresh press that starts with the search already empty, never on key repeat:
/// holding ⌫ to clear the search must not go on to delete cards once the text is gone.
struct DeleteKeyGuard {
    private var pressStartedEmpty = false
    mutating func allows(isRepeat: Bool, searchEmpty: Bool) -> Bool {
        if !isRepeat { pressStartedEmpty = searchEmpty; return searchEmpty }
        return false
    }
}
