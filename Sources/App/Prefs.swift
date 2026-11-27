import Foundation

/// UserDefaults keys. Values not yet set read as the defaults below.
enum Pref {
    static let historyDays = "historyDays"      // Int, 30; 0 = keep forever
    static let kinds = "kinds"                  // [String] of ItemKind raw values; unset = all
    static let excluded = "excluded"            // [String] bundle ids; unset = CaptureRules.defaultExcluded
    static let linkPreviews = "linkPreviews"    // Bool, true
    static let autoPaste = "autoPaste"          // Bool, true
    static let showMenuBar = "showMenuBar"      // Bool, true
    static let didSetUp = "didSetUp"            // Bool
    static let soundOnCopy = "soundOnCopy"      // Bool, true: a sound when a copy is saved
    static let soundOnPaste = "soundOnPaste"    // Bool, true: a sound when Mneme pastes
    static let sound = "sound"                  // String, the copy sound: a MadeSound raw value or "system:<name>"
    static let pasteSound = "pasteSound"        // String, the paste sound, same values
    static let soundLevel = "soundLevel"        // Double 0...1, 0.4
    static let soundSteady = "soundSteady"      // Bool, true: the same loudness whatever the Mac's volume
    static let shelfMotion = "shelfMotion"      // String, a ShelfMotion raw value: how the shelf opens and closes
    static let formatOnCommandV = "formatOnCommandV" // Bool, true: ⌘V in any app gets the form of a text copy that suits it
    static let formatFromMneme = "formatFromMneme"   // Bool, true: the same for pastes from the shelf
    static let pasteLearning = "pasteLearning"       // Data, JSON PasteLearning: the user's choices per place
    static let autoUpdate = "autoUpdate"             // Bool, true: install a downloaded update on its own while Mneme is idle
    static let updateFeed = "updateFeed"             // String, a manifest URL in place of the release feed (testing)
    static let updateLastChecked = "updateLastChecked" // Date
    static let lastRunVersion = "lastRunVersion"     // String, the version that ran last, to say when it was updated
    static let defaultSound = MadeSound.drop.rawValue
    static let defaultPasteSound = MadeSound.pluck.rawValue
    // Shortcuts live under Shortcuts.key.

    static func register(_ d: UserDefaults = .standard) {
        d.register(defaults: [historyDays: 30, linkPreviews: true, autoPaste: true, showMenuBar: true,
                                 soundOnCopy: true, soundOnPaste: true, sound: defaultSound, pasteSound: defaultPasteSound, soundLevel: 0.4, soundSteady: true,
                                 shelfMotion: ShelfMotion.standard.rawValue,
                                 formatOnCommandV: true, formatFromMneme: true, autoUpdate: true])
    }
}

func captureRules(_ d: UserDefaults, paused: Bool, ownChangeCount: Int?) -> CaptureRules {
    var r = CaptureRules()
    if let kinds = d.stringArray(forKey: Pref.kinds) { r.kinds = Set(kinds.compactMap(ItemKind.init(rawValue:))) }
    if let excluded = d.stringArray(forKey: Pref.excluded) { r.excludedBundleIDs = Set(excluded) }
    r.paused = paused
    r.ownChangeCount = ownChangeCount
    return r
}

/// nil = keep forever.
func historyMaxAge(_ d: UserDefaults) -> TimeInterval? {
    let days = d.object(forKey: Pref.historyDays) as? Int ?? 30
    return days > 0 ? TimeInterval(days) * 86_400 : nil
}
