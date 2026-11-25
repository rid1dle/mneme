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
    // Shortcuts live under Shortcuts.key.

    static func register(_ d: UserDefaults = .standard) {
        d.register(defaults: [historyDays: 30, linkPreviews: true, autoPaste: true, showMenuBar: true])
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
