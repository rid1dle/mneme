import SwiftUI

/// Mneme's shortcut button: the kit's recorder, with "back to the default" and "no shortcut" beside it. Any combo is
/// taken here (shelf shortcuts may be a single key, ⌫ among them); SettingsModel.set says what is wrong with one.
/// Mneme's own shortcuts pause while recording, so pressing one records it instead of running it.
struct HotkeyRecorder: View {
    let action: ShortcutAction
    @ObservedObject var settings: SettingsModel

    var body: some View {
        ShortcutRecorder(combo: settings.shortcuts[action], defaultCombo: action.defaultCombo, withButtons: true,
                         deleteClears: false, allows: { _ in true },
                         onRecording: { on in
                             if on { settings.problems[action] = nil }
                             settings.suspendHotkeys(on)
                         },
                         id: "record-\(action.rawValue)") { settings.set(action, $0) }
    }
}
