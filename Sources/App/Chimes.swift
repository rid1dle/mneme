import AppKit
import CoreAudio

enum ChimeEvent { case copy, paste }

/// Plays the confirmation sounds. Sounds are made on first use and kept, so nothing audio loads while sounds are off.
@MainActor
final class Chimes {
    static let shared = Chimes()
    private var cache: [String: NSSound] = [:]

    /// The Mac's own sounds offered next to Mneme's, those present on this Mac.
    static let systemNames = ["Pop", "Purr", "Tink", "Bottle", "Glass", "Morse"].filter {
        FileManager.default.fileExists(atPath: "/System/Library/Sounds/\($0).aiff")
    }

    /// False when the event's sound is switched off.
    @discardableResult
    func play(_ event: ChimeEvent, defaults d: UserDefaults = .standard) -> Bool {
        guard d.bool(forKey: event == .copy ? Pref.soundOnCopy : Pref.soundOnPaste) else { return false }
        play(Self.soundID(for: event, defaults: d), level: d.double(forKey: Pref.soundLevel), steady: d.bool(forKey: Pref.soundSteady))
        return true
    }

    static func soundID(for event: ChimeEvent, defaults d: UserDefaults) -> String {
        event == .copy ? d.string(forKey: Pref.sound) ?? Pref.defaultSound : d.string(forKey: Pref.pasteSound) ?? Pref.defaultPasteSound
    }

    /// Also the preview in Settings.
    func play(_ id: String, level: Double, steady: Bool) {
        let output = outputLevel()
        guard !output.muted, let s = sound(id, level: level, steady: steady, deviceDecibels: output.decibels) else { return }
        s.stop()
        s.play()
    }

    /// The sound for a saved choice with its volume set; a system sound that is gone falls back to the default.
    func sound(_ id: String, level: Double, steady: Bool, deviceDecibels: Double?) -> NSSound? {
        let key = sound(named: id) != nil ? id : Pref.defaultSound
        guard let s = sound(named: key) else { return nil }
        s.volume = Float(chimeGain(level: level, steady: steady, deviceDecibels: deviceDecibels))
        return s
    }

    private func sound(named id: String) -> NSSound? {
        if let s = cache[id] { return s }
        let s: NSSound?
        if let name = chimeSystemName(id) {
            s = Self.systemNames.contains(name) ? NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true) : nil
        } else {
            s = MadeSound(rawValue: id).flatMap { NSSound(data: $0.wav()) }
        }
        cache[id] = s
        return s
    }
}

/// The default output's level in decibels (nil when it has no volume control, as some HDMI and AirPlay outputs do)
/// and whether it is muted. Read fresh on each play: a few property reads.
/// The volume slider's position is converted with the output's own curve: Bluetooth speakers report a fixed 0 dB as
/// their level while their slider and curve are right (a speaker at 75% reads 0 dB, its curve says -10 dB).
func outputLevel() -> (decibels: Double?, muted: Bool) {
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
          device != 0 else { return (nil, false) }

    // Some outputs keep the volume on the main element, others per channel.
    func element(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress? {
        for e in [kAudioObjectPropertyElementMain, 1, 2] {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: e)
            if AudioObjectHasProperty(device, &a) { return a }
        }
        return nil
    }
    func read<T>(_ selector: AudioObjectPropertySelector, _ start: T) -> T? {
        guard var a = element(selector) else { return nil }
        var v = start, n = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &n, &v) == noErr ? v : nil
    }

    let muted = (read(kAudioDevicePropertyMute, UInt32(0)) ?? 0) != 0
    if let scalar = read(kAudioDevicePropertyVolumeScalar, Float32(0)) {
        guard scalar > 0 else { return (nil, true) }
        if var a = element(kAudioDevicePropertyVolumeScalarToDecibels) {
            var v = scalar, n = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &a, 0, nil, &n, &v) == noErr { return (Double(v), muted) }
        }
        return (approxDecibels(fromScalar: Double(scalar)), muted)
    }
    if let db = read(kAudioDevicePropertyVolumeDecibels, Float32(0)) { return (Double(db), muted) }
    return (nil, muted)
}
