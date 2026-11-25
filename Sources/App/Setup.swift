import AppKit
import ServiceManagement
import SwiftUI

/// Shown once: the shortcut, clipboard access, Accessibility and open at login. The only place Mneme ever asks
/// macOS for a permission.
struct SetupView: View {
    @ObservedObject var settings: SettingsModel
    let done: () -> Void
    @EnvironmentObject var theme: ThemeStore
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Mneme").font(.system(size: 20, weight: .semibold))
                    Text("Everything you copy, one shortcut away.").foregroundStyle(.secondary)
                }
            }
            step(1, "Your shortcut", ok: true) {
                HStack {
                    Text("Opens Mneme from any app.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    HotkeyRecorder(action: .openShelf, settings: settings)
                }
            }
            step(2, "Let Mneme see what you copy", ok: settings.clipboardAllowed) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.clipboardAllowed
                         ? "Allowed. macOS may ask about this later; if it does, choose Always Allow."
                         : "macOS asks before an app reads the clipboard. Choose Always Allow for Mneme in Paste from Other Apps; “Allow Paste” only allows it once.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !settings.clipboardAllowed {
                        Button("Open Paste from Other Apps") {
                            Watcher.introduceToPasteboardPrivacy()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!)
                        }
                    }
                }
            }
            step(3, "Let Mneme paste for you", ok: settings.accessibility) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.accessibility
                         ? "Allowed. Picking an item pastes it, and ⌘V runs the paste stack."
                         : "Optional. Without it, picking an item copies it and you press ⌘V yourself.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !settings.accessibility {
                        Button("Allow in Accessibility") {
                            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                        }
                    }
                }
            }
            step(4, "Start with your Mac", ok: settings.openAtLogin) {
                Toggle("Open Mneme at login", isOn: Binding(get: { settings.openAtLogin }, set: { settings.setOpenAtLogin($0) }))
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(26)
        .frame(width: 520)
        .tint(theme.accent)
        .onReceive(tick) { _ in settings.refreshPermissions() }
    }

    private func step<Content: View>(_ n: Int, _ title: String, ok: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(ok ? Color.green : theme.accent).frame(width: 24, height: 24)
                if ok { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                content()
            }
        }
    }
}
