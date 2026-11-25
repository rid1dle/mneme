import AppKit
import SwiftUI

/// Click, then press the new shortcut. Esc cancels. Problems (taken, needs a modifier) show under the row.
struct HotkeyRecorder: View {
    let action: ShortcutAction
    @ObservedObject var settings: SettingsModel
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : (settings.shortcuts[action]?.display ?? "None"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            .accessibilityIdentifier("record-\(action.rawValue)")
            Button { settings.set(action, action.defaultCombo) } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless).help("Back to \(action.defaultCombo?.display ?? "none")")
                .disabled(settings.shortcuts[action] == action.defaultCombo)
            Button { settings.set(action, nil) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).help("No shortcut")
                .disabled(settings.shortcuts[action] == nil)
        }
        .onDisappear { stop() }
    }

    private func start() {
        settings.problems[action] = nil
        recording = true
        settings.suspendHotkeys(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                stop()
                return nil
            }
            settings.set(action, KeyCombo(event: event))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { settings.suspendHotkeys(false) }
        recording = false
    }
}
