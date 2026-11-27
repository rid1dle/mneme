import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// What the Settings window reads and changes. Store writes go through the store queue.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var shortcuts: Shortcuts
    @Published var problems: [ShortcutAction: String] = [:]
    @Published var pinboards: [Pinboard] = []
    @Published var accessibility = AXIsProcessTrusted()
    @Published var clipboardAllowed = Watcher.accessAllowed()
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var excluded: [String]
    @AppStorage(Pref.historyDays) var historyDays = 30
    @AppStorage(Pref.autoPaste) var autoPaste = true
    @AppStorage(Pref.linkPreviews) var linkPreviews = true
    @AppStorage(Pref.showMenuBar) var showMenuBar = true
    @AppStorage(Pref.soundOnCopy) var soundOnCopy = true
    @AppStorage(Pref.soundOnPaste) var soundOnPaste = true
    @AppStorage(Pref.sound) var sound = Pref.defaultSound
    @AppStorage(Pref.pasteSound) var pasteSound = Pref.defaultPasteSound
    @AppStorage(Pref.soundLevel) var soundLevel = 0.4
    @AppStorage(Pref.soundSteady) var soundSteady = true
    @AppStorage(Pref.formatOnCommandV) var formatOnCommandV = true
    @AppStorage(Pref.formatFromMneme) var formatFromMneme = true
    @Published var learned: [(key: String, name: String, version: PasteVersion)] = []

    func reloadLearned() { learned = app?.formatter?.learnedRules ?? [] }
    func forget(_ key: String?) { app?.formatter?.forget(key); reloadLearned() }
    func showPasteLog() {
        let url = LaunchOptions.current.storeDirectory.appendingPathComponent("paste-log.jsonl")
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
    }

    func previewSound(_ id: String) { Chimes.shared.play(id, level: soundLevel, steady: soundSteady) }

    let store: Store
    let storeQueue: DispatchQueue
    weak var app: AppDelegate?

    init(app: AppDelegate) {
        self.app = app
        store = app.store
        storeQueue = app.storeQueue
        shortcuts = app.shortcuts
        excluded = UserDefaults.standard.stringArray(forKey: Pref.excluded) ?? CaptureRules.defaultExcluded.sorted()
        reloadPinboards()
    }

    func refreshPermissions() {
        accessibility = AXIsProcessTrusted()
        clipboardAllowed = Watcher.accessAllowed()
        openAtLogin = SMAppService.mainApp.status == .enabled
        app?.updatePasteTap()
    }

    // MARK: shortcuts

    func set(_ action: ShortcutAction, _ combo: KeyCombo?) {
        problems[action] = nil
        if let combo, let p = shortcuts.problem(combo, for: action) { problems[action] = p.message; return }
        guard app?.setShortcut(action, combo) == true else {
            problems[action] = "Another app already uses \(combo?.display ?? "this shortcut")"
            return
        }
        shortcuts = app?.shortcuts ?? shortcuts
    }

    func suspendHotkeys(_ on: Bool) { app?.suspendHotkeys(on) }

    // MARK: general

    func setOpenAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    var kinds: Set<ItemKind> {
        get { Set((UserDefaults.standard.stringArray(forKey: Pref.kinds) ?? ItemKind.allCases.map(\.rawValue)).compactMap(ItemKind.init(rawValue:))) }
        set { objectWillChange.send(); UserDefaults.standard.set(ItemKind.allCases.filter(newValue.contains).map(\.rawValue), forKey: Pref.kinds) }
    }

    func setExcluded(_ ids: [String]) {
        excluded = ids
        UserDefaults.standard.set(ids, forKey: Pref.excluded)
    }

    func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        setExcluded(Array(Set(excluded + ids)).sorted())
    }

    func clearHistory() {
        storeQueue.async { [store] in try? store.clearHistory(now: Date()) }
    }

    // MARK: pinboards

    func reloadPinboards() {
        storeQueue.async { [store] in
            let boards = (try? store.allPinboards()) ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated { self.pinboards = boards } }
        }
    }

    func editPinboards(_ body: @escaping @Sendable (Store) throws -> Void) {
        storeQueue.async { [store] in
            try? body(store)
            let boards = (try? store.allPinboards()) ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated { self.pinboards = boards } }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsModel
    @EnvironmentObject var theme: ThemeStore
    @State var tab: String

    private static let tabs: [(id: String, name: String, icon: String)] = [
        ("general", "General", "gearshape"), ("shortcuts", "Shortcuts", "command"), ("history", "History", "clock"),
        ("pasting", "Pasting", "doc.on.clipboard"), ("sound", "Sound", "speaker.wave.2"), ("privacy", "Privacy", "hand.raised"), ("appearance", "Appearance", "paintpalette"), ("pinboards", "Pinboards", "pin"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Self.tabs, id: \.id) { t in
                    Button { tab = t.id } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icon).font(.system(size: 17)).frame(height: 20)
                            Text(t.name).font(.system(size: 11))
                        }
                        .frame(width: 72, height: 48)
                        .foregroundStyle(tab == t.id ? theme.accent : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tab == t.id ? Color.primary.opacity(0.08) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t.name)
                    .accessibilityAddTraits(tab == t.id ? .isSelected : [])
                }
            }
            .padding(.vertical, 8)
            Divider()
            Group {
                switch tab {
                case "shortcuts": ShortcutsTab(settings: settings)
                case "history": HistoryTab(settings: settings)
                case "sound": SoundTab(settings: settings)
                case "pasting": PastingTab(settings: settings)
                case "privacy": PrivacyTab(settings: settings)
                case "appearance": AppearanceTab()
                case "pinboards": PinboardsTab(settings: settings)
                default: GeneralTab(settings: settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 560)
        .tint(theme.accent)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in settings.refreshPermissions() }
    }
}

private struct StatusRow: View {
    let title: String
    let ok: Bool
    let okText: String
    let fixText: String
    let detail: String
    let fix: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(ok ? okText : detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !ok { Button(fixText, action: fix) }
        }
    }
}

struct GeneralTab: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Open Mneme at login", isOn: Binding(get: { settings.openAtLogin }, set: { settings.setOpenAtLogin($0) }))
                Toggle("Show Mneme in the menu bar", isOn: $settings.showMenuBar)
                    .onChange(of: settings.showMenuBar) { settings.app?.applyMenuBar() }
                if !settings.showMenuBar {
                    Text("To get back here, open Mneme again from Applications, or use the gear in the shelf.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Toggle("Paste into the app I was in (not only copy)", isOn: $settings.autoPaste)
            }
            Section("Permissions") {
                StatusRow(title: "Clipboard access", ok: settings.clipboardAllowed, okText: "Mneme can save what you copy.",
                          fixText: "Open Settings", detail: "Set Mneme to Always Allow in Paste from Other Apps, or nothing is saved.") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!)
                }
                StatusRow(title: "Accessibility", ok: settings.accessibility, okText: "Mneme can press ⌘V for you and run the paste stack.",
                          fixText: "Open Settings", detail: "Needed to paste for you and for ⌘V in the paste stack. Without it, items are copied and you press ⌘V.") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutsTab: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        Form {
            Section("Anywhere") {
                ForEach(ShortcutAction.allCases.filter(\.isGlobal), id: \.self) { row($0) }
            }
            Section("In the shelf") {
                ForEach(ShortcutAction.allCases.filter { !$0.isGlobal }, id: \.self) { row($0) }
                Text("Fixed: ← → move, Return pastes, ⌘1 to ⌘9 paste one of the first nine, Esc closes. Shortcuts without ⌘, ⌃ or ⌥ type into the search while it has text.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ a: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(a.title)
                Spacer()
                HotkeyRecorder(action: a, settings: settings)
            }
            if let note = a.note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
            if let p = settings.problems[a] { Text(p).font(.system(size: 11, weight: .medium)).foregroundStyle(.red) }
        }
    }
}

struct HistoryTab: View {
    @ObservedObject var settings: SettingsModel
    @State private var confirmClear = false
    private let ages: [(String, Int)] = [("1 day", 1), ("1 week", 7), ("1 month", 30), ("3 months", 90), ("1 year", 365), ("Forever", 0)]
    private let kindNames: [(ItemKind, String)] = [(.text, "Text"), (.richText, "Rich text"), (.image, "Images"), (.file, "Files"), (.link, "Links"), (.color, "Colors")]

    var body: some View {
        Form {
            Section {
                Picker("Keep history for", selection: $settings.historyDays) {
                    ForEach(ages, id: \.1) { Text($0.0).tag($0.1) }
                }
                Text("Pinboards are kept forever, whatever this says.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Save") {
                ForEach(kindNames, id: \.0) { kind, name in
                    Toggle(name, isOn: Binding(get: { settings.kinds.contains(kind) },
                                               set: { on in var k = settings.kinds; if on { k.insert(kind) } else { k.remove(kind) }; settings.kinds = k }))
                }
            }
            Section {
                Button("Clear History…", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Clear all of History?", isPresented: $confirmClear) {
                        Button("Clear History", role: .destructive) { settings.clearHistory() }
                    } message: { Text("Items on pinboards stay on their pinboards.") }
            }
        }
        .formStyle(.grouped)
    }
}

struct PastingTab: View {
    @ObservedObject var settings: SettingsModel

    private static let rules: [(place: String, gets: String)] = [
        ("Excel, Numbers, Google Sheets", "Everything as copied, colours and cell styling included"),
        ("Gmail, Mail, Docs, Notion, Slack and other apps", "Bullets, bold, links, code and tables kept; colours, backgrounds and fonts dropped"),
        ("Code editors", "Markdown: bold, numbered lists and tables kept; code exactly as copied"),
        ("Terminals, and the terminal in VS Code or Cursor", "Text only: no Markdown, bullets or indents; code keeps its own layout"),
        ("WhatsApp, Telegram, Messages", "Plain text, lists as • bullets"),
        ("The app it was copied from", "Exactly as copied"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Fix formatting when I paste in any app", isOn: $settings.formatOnCommandV)
                    .onChange(of: settings.formatOnCommandV) { settings.app?.updatePasteTap() }
                Toggle("Fix formatting when I paste from Mneme", isOn: $settings.formatFromMneme)
                Text(settings.accessibility
                     ? "Text you copy is pasted in the form that suits the app, or the site in a browser, it goes into: with ⌘V, Edit > Paste, a right click or the paste stack. Plain text written as Markdown, and rich text from Word, Pages or Notes, become clean formatted text in apps that take formatting."
                     : "Accessibility is off, so this works only when you switch apps and not on ⌘V inside a browser: allow it in General.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("What each place gets") {
                ForEach(Self.rules, id: \.place) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.place).font(.system(size: 12, weight: .medium))
                        Text(r.gets).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text("Any other way, any time: \(settings.shortcuts[.pastePlainNow]?.display ?? "the plain text shortcut") pastes plain text and \(settings.shortcuts[.pasteOriginalNow]?.display ?? "the original shortcut") the original. In the shelf, ⇧↩ and ⌥↩ do the same.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Learned from you") {
                if settings.learned.isEmpty {
                    Text("Nothing yet. Choose plain text or the original the same way twice in one place, and Mneme does it that way there from then on.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(settings.learned, id: \.key) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name).font(.system(size: 12))
                                Text(rule.version.name).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { settings.forget(rule.key) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Forget")
                                .accessibilityLabel("Forget \(rule.name)")
                        }
                    }
                    Button("Forget All") { settings.forget(nil) }
                }
                Button("Show Paste Log") { settings.showPasteLog() }
                Text("Where each paste went and the form it got, never what was in it, kept on this Mac to improve these rules.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { settings.reloadLearned() }
    }
}

struct SoundTab: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        Form {
            Section("When something is copied") {
                Toggle("Play a sound", isOn: $settings.soundOnCopy)
                SoundPicker(selection: $settings.sound, settings: settings).disabled(!settings.soundOnCopy)
            }
            Section("When Mneme pastes for you") {
                Toggle("Play a sound", isOn: $settings.soundOnPaste)
                SoundPicker(selection: $settings.pasteSound, settings: settings).disabled(!settings.soundOnPaste)
            }
            Section {
                LabeledContent("Loudness") {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                        Slider(value: $settings.soundLevel, in: 0...1) { editing in
                            if !editing { settings.previewSound(settings.soundOnCopy || !settings.soundOnPaste ? settings.sound : settings.pasteSound) }
                        }
                        .accessibilityLabel("Loudness")
                        Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 260)
                }
                Toggle("Same loudness at any Mac volume", isOn: $settings.soundSteady)
                Text(settings.soundSteady
                     ? "Turning your Mac up or down does not change these sounds. They only get quieter when the Mac is set below them, and they are silent when the Mac is muted."
                     : "These sounds get louder and quieter with your Mac's volume, like other sounds.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!settings.soundOnCopy && !settings.soundOnPaste)
        }
        .formStyle(.grouped)
    }
}

/// A sound choice with a button to hear it; picking one plays it.
private struct SoundPicker: View {
    @Binding var selection: String
    @ObservedObject var settings: SettingsModel

    var body: some View {
        HStack {
            Picker("Sound", selection: $selection) {
                Section("Mneme") {
                    ForEach(MadeSound.allCases, id: \.self) { Text($0.name).tag($0.rawValue) }
                }
                Section("Mac") {
                    ForEach(Chimes.systemNames, id: \.self) { Text($0).tag("system:\($0)") }
                }
            }
            Button { settings.previewSound(selection) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
                .help("Play")
                .accessibilityLabel("Play")
        }
        .onChange(of: selection) { settings.previewSound(selection) }
    }
}

struct PrivacyTab: View {
    @ObservedObject var settings: SettingsModel
    static let knownNames = ["com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
                             "com.apple.keychainaccess": "Keychain Access", "com.apple.Passwords": "Passwords"]

    var body: some View {
        Form {
            Section {
                Label("Passwords and other secrets that password managers mark are never saved.", systemImage: "lock.shield")
                    .font(.system(size: 12))
            }
            Section("Never save what I copy in") {
                ForEach(settings.excluded, id: \.self) { id in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                            Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                        } else {
                            Image(systemName: "app.dashed").frame(width: 18)
                            Text(Self.knownNames[id] ?? id)
                            Text("not installed").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button { settings.setExcluded(settings.excluded.filter { $0 != id }) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add App…") { settings.addExcludedApp() }
            }
            Section {
                Toggle("Show page titles and images for copied links", isOn: $settings.linkPreviews)
                Text("Mneme reads only the start of the page. This is its only use of the network.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceTab: View {
    @EnvironmentObject var theme: ThemeStore

    var body: some View {
        Form {
            Section("Themes") {
                HStack(spacing: 12) {
                    ForEach(themePresets, id: \.name) { p in
                        Button { theme.theme = p.theme } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(p.theme.appearance == .dark ? Color(white: 0.15) : p.theme.appearance == .light ? Color(white: 0.96) : Color(white: 0.55))
                                    .overlay(Circle().fill(Color(hex: p.theme.accent)).frame(width: 18, height: 18))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(theme.theme == p.theme ? Color(hex: p.theme.accent) : Color.primary.opacity(0.15), lineWidth: theme.theme == p.theme ? 3 : 1))
                                    .frame(width: 96, height: 60)
                                Text(p.name).font(.system(size: 12))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section {
                Picker("Appearance", selection: $theme.theme.appearance) {
                    Text("Match the system").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                ColorPicker("Accent colour", selection: Binding(get: { Color(hex: theme.theme.accent) }, set: { c in
                    if let hex = NSColor(c).usingColorSpace(.sRGB).map({ String(format: "#%02X%02X%02X", Int(($0.redComponent * 255).rounded()), Int(($0.greenComponent * 255).rounded()), Int(($0.blueComponent * 255).rounded())) }) {
                        theme.theme.accent = hex
                    }
                }), supportsOpacity: false)
                Picker("Shelf", selection: $theme.theme.shelf) {
                    Text("Glass").tag(ShelfStyle.glass)
                    Text("Solid").tag(ShelfStyle.solid)
                }
                .pickerStyle(.segmented)
                Picker("Card size", selection: $theme.theme.cardSize) {
                    Text("Small").tag(CardSize.small)
                    Text("Medium").tag(CardSize.medium)
                    Text("Large").tag(CardSize.large)
                }
                .pickerStyle(.segmented)
            }
            Section("Opening and closing") {
                MotionChoices()
            }
        }
        .formStyle(.grouped)
    }
}

/// The shelf's animation styles as tiles; the chosen one, or the one under the pointer, plays its preview on a loop.
private struct MotionChoices: View {
    @EnvironmentObject var theme: ThemeStore
    @AppStorage(Pref.shelfMotion) private var saved = ShelfMotion.standard.rawValue
    @State private var hovered: ShelfMotion?

    var body: some View {
        let chosen = ShelfMotion(saved: saved)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ForEach(ShelfMotion.allCases, id: \.self) { m in
                    Button { saved = m.rawValue } label: {
                        VStack(spacing: 6) {
                            MotionPreview(motion: m, playing: (hovered ?? chosen) == m)
                                .frame(width: 120, height: 76)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(chosen == m ? theme.accent : Color.primary.opacity(0.15), lineWidth: chosen == m ? 3 : 1))
                            Text(m.name).font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in hovered = inside ? m : (hovered == m ? nil : hovered) }
                    .accessibilityLabel(m.name)
                    .accessibilityHint(m.detail)
                    .accessibilityAddTraits(chosen == m ? .isSelected : [])
                }
            }
            Text((hovered ?? chosen).detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// A small screen with a shelf at its bottom, moving the way the real one does. Draws only while playing.
private struct MotionPreview: View {
    let motion: ShelfMotion
    let playing: Bool
    @EnvironmentObject var theme: ThemeStore
    @Environment(\.colorScheme) private var scheme
    @State private var start = Date()

    private static let shelfHeight = 26.0

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !playing)) { context in
            let pose = playing ? motion.loopPose(at: context.date.timeIntervalSince(start), shelfHeight: Self.shelfHeight, pointScale: 0.4) : .rest
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [theme.accent.opacity(0.35), theme.accent.opacity(0.1)], startPoint: .top, endPoint: .bottom)
                shelf
                    .scaleEffect(pose.scale)
                    .offset(y: pose.drop)
                    .opacity(pose.opacity)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .onChange(of: playing) { if playing { start = Date() } }
    }

    private var shelf: some View {
        VStack(spacing: 0) {
            theme.accent.frame(height: 4)
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.primary.opacity(0.18))
                }
            }
            .padding(3)
        }
        .frame(height: Self.shelfHeight)
        .background(scheme == .dark ? Color(white: 0.2) : Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }
}

struct PinboardsTab: View {
    @ObservedObject var settings: SettingsModel
    @State private var deleting: Pinboard?

    var body: some View {
        Form {
            Section {
                ForEach(Array(settings.pinboards.enumerated()), id: \.element.id) { n, board in
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(ShelfModel.pinboardColors, id: \.self) { c in
                                Button { settings.editPinboards { try $0.recolorPinboard(board.id, color: c, now: Date()) } } label: {
                                    Label(c, systemImage: "circle.fill")
                                }
                            }
                        } label: { Circle().fill(Color(hex: board.color)).frame(width: 14, height: 14) }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                            .accessibilityLabel("Colour")
                        TextField("", text: Binding(get: { board.name }, set: { name in
                            settings.editPinboards { try $0.renamePinboard(board.id, name: name, now: Date()) }
                        }), prompt: Text("Name"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        Spacer()
                        Button { settings.editPinboards { try $0.movePinboard(board.id, to: n - 1) } } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(n == 0)
                        Button { settings.editPinboards { try $0.movePinboard(board.id, to: n + 1) } } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(n == settings.pinboards.count - 1)
                        Button { deleting = board } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                if settings.pinboards.isEmpty {
                    Text("No pinboards yet.").foregroundStyle(.secondary)
                }
                Button("New Pinboard") {
                    let color = ShelfModel.pinboardColors[settings.pinboards.count % ShelfModel.pinboardColors.count]
                    settings.editPinboards { _ = try $0.createPinboard(name: "New pinboard", color: color, now: Date()) }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Pinboard", role: .destructive) {
                if let id = deleting?.id { settings.editPinboards { try $0.deletePinboard(id, now: Date()) } }
            }
        } message: { Text("Its items stay in History if they are there; the rest are deleted.") }
    }
}
