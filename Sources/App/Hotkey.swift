import Carbon.HIToolbox
import Foundation

/// A key plus Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey).
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

}

/// A system-wide shortcut through Carbon's RegisterEventHotKey, which needs no permission.
@MainActor
final class Hotkey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    private let id: UInt32
    private var ref: EventHotKeyRef?
    private(set) var combo: KeyCombo?

    /// `combo` nil = no shortcut for now (set one later with `update`).
    init(_ combo: KeyCombo?, action: @escaping () -> Void) {
        Hotkey.installHandler()
        id = Hotkey.nextID
        Hotkey.nextID += 1
        self.combo = combo
        Hotkey.handlers[id] = action
        if let combo { _ = register(combo) }
    }

    /// False when the combo is taken by another app (the old one stays registered). nil removes the shortcut.
    func update(_ new: KeyCombo?) -> Bool {
        let old = ref
        guard let new else {
            if let old { UnregisterEventHotKey(old) }
            ref = nil
            combo = nil
            return true
        }
        if register(new) {
            if let old { UnregisterEventHotKey(old) }
            combo = new
            return true
        }
        ref = old
        return false
    }

    private func register(_ c: KeyCombo) -> Bool {
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(c.keyCode, c.modifiers, EventHotKeyID(signature: OSType(0x4D4E4D45), id: id),
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return false }
        ref = newRef
        return true
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkey.handlers[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

extension KeyCombo {
    /// ⌃⌥⇧⌘ order, then the key: "⇧⌘V".
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    var keyName: String {
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
                                      kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        if let s = special[Int(keyCode)] { return s }
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        ]
        return letters[Int(keyCode)] ?? "Key \(keyCode)"
    }
}
