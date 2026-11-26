import Foundation

private func samples(_ wav: Data) -> [Int16] {
    wav.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
}

private func le32(_ d: Data, _ at: Int) -> UInt32 {
    d.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
}

let chimeTests: [TestCase] = [
    test("should keep the same loudness when the Mac's volume goes up") {
        let target = chimeTargetDecibels(level: 0.5)
        let quietMac = chimeGain(level: 0.5, steady: true, deviceDecibels: -30)
        let loudMac = chimeGain(level: 0.5, steady: true, deviceDecibels: -10)
        expect(abs(20 * log10(quietMac) + -30 - target) < 0.001, "heard level at a quiet Mac")
        expect(abs(20 * log10(loudMac) + -10 - target) < 0.001, "heard level at a loud Mac")
        expect(loudMac < quietMac, "a louder Mac gets a quieter sound")
    },
    test("should play at full strength, never louder, when the Mac is quieter than the chosen level") {
        expectEqual(chimeGain(level: 1, steady: true, deviceDecibels: -60), 1)
    },
    test("should follow the Mac's volume when steady loudness is off") {
        expectEqual(chimeGain(level: 0.5, steady: false, deviceDecibels: -30), chimeGain(level: 0.5, steady: false, deviceDecibels: 0))
    },
    test("should fall back to a fixed level when the output has no volume to read") {
        expectEqual(chimeGain(level: 0.5, steady: true, deviceDecibels: nil), chimeGain(level: 0.5, steady: false, deviceDecibels: nil))
    },
    test("should make the steady and the plain level match at a middle Mac volume") {
        let steady = chimeGain(level: 0.3, steady: true, deviceDecibels: chimeReferenceDecibels)
        expect(abs(steady - chimeGain(level: 0.3, steady: false, deviceDecibels: nil)) < 0.0001)
    },
    test("should map the loudness slider from quiet to loud in order") {
        expectEqual(chimeTargetDecibels(level: 0), -50)
        expectEqual(chimeTargetDecibels(level: 1), -14)
        expect(chimeTargetDecibels(level: 0.2) < chimeTargetDecibels(level: 0.8))
        expectEqual(chimeTargetDecibels(level: 7), -14, "out of range levels are clamped")
    },
    test("should read a volume slider position as decibels when the output gives no decibels") {
        expectEqual(approxDecibels(fromScalar: 1), 0)
        expect(abs(approxDecibels(fromScalar: 0.5)! - -12.04) < 0.01)
        expect(approxDecibels(fromScalar: 0) == nil, "a volume of zero is silence, not a level")
    },
    test("should make every built-in sound a short, valid sound file that starts and ends quietly") {
        for sound in MadeSound.allCases {
            let wav = sound.wav()
            expectEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF", sound.rawValue)
            expectEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE", sound.rawValue)
            expectEqual(le32(wav, 24), 44_100, sound.rawValue)
            expectEqual(Int(le32(wav, 40)), wav.count - 44, sound.rawValue)
            let s = samples(wav)
            let seconds = Double(s.count) / 44_100
            expect(seconds > 0.04 && seconds < 0.6, "\(sound.rawValue) lasts \(seconds) s")
            expect(abs(Int(s.first!)) < 300, "\(sound.rawValue) starts without a click")
            expect(abs(Int(s.last!)) < 300, "\(sound.rawValue) ends without a click")
            let peak = s.map { abs(Int($0)) }.max()!
            expect(peak > 20_000 && peak <= 32_767, "\(sound.rawValue) peak \(peak)")
        }
    },
    test("should offer the built-in sounds by name and know a system sound from a made one") {
        expectEqual(MadeSound(rawValue: Pref.defaultSound), .drop)
        expectEqual(chimeSystemName("system:Pop"), "Pop")
        expect(chimeSystemName("drop") == nil)
    },
    test("should default to a sound on copy and on paste, the gentle built-in ones, steady and fairly quiet") {
        let d = UserDefaults(suiteName: "mneme-chime-\(UUID().uuidString)")!
        Pref.register(d)
        expectEqual(d.bool(forKey: Pref.soundOnCopy), true)
        expectEqual(d.bool(forKey: Pref.soundOnPaste), true)
        expectEqual(d.string(forKey: Pref.pasteSound), "pluck")
        expectEqual(d.string(forKey: Pref.sound), "drop")
        expectEqual(d.double(forKey: Pref.soundLevel), 0.4)
        expectEqual(d.bool(forKey: Pref.soundSteady), true)
    },
]

let chimePlayerTests: [TestCase] = [
    test("should load every built-in sound as a sound macOS can play") {
        MainActor.assumeIsolated {
            for sound in MadeSound.allCases {
                expect(Chimes.shared.sound(sound.rawValue, level: 0.4, steady: true, deviceDecibels: -20) != nil, sound.rawValue)
            }
        }
    },
    test("should set the sound's own volume from the loudness and the Mac's level") {
        MainActor.assumeIsolated {
            let s = Chimes.shared.sound("pluck", level: 0.5, steady: true, deviceDecibels: -10)
            expectEqual(s?.volume, Float(chimeGain(level: 0.5, steady: true, deviceDecibels: -10)))
        }
    },
    test("should fall back to the default sound when a chosen system sound is missing") {
        MainActor.assumeIsolated {
            expect(Chimes.shared.sound("system:NoSuchSound", level: 0.4, steady: true, deviceDecibels: nil) != nil)
        }
    },
    test("should read the Mac's output level as a sane number of decibels, or nothing") {
        MainActor.assumeIsolated {
            let level = outputLevel()
            if let db = level.decibels { expect(db <= 0.01 && db > -130, "\(db) dB") }
        }
    },
    test("should give pasting its own sound, different from the copy sound by default") {
        MainActor.assumeIsolated {
            let d = UserDefaults(suiteName: "mneme-chime-\(UUID().uuidString)")!
            Pref.register(d)
            expectEqual(Chimes.soundID(for: .copy, defaults: d), "drop")
            expectEqual(Chimes.soundID(for: .paste, defaults: d), "pluck")
            d.set("system:Glass", forKey: Pref.pasteSound)
            expectEqual(Chimes.soundID(for: .paste, defaults: d), "system:Glass")
            expectEqual(Chimes.soundID(for: .copy, defaults: d), "drop", "changing the paste sound leaves the copy sound alone")
        }
    },
    test("should play nothing for an event that is switched off") {
        MainActor.assumeIsolated {
            let d = UserDefaults(suiteName: "mneme-chime-\(UUID().uuidString)")!
            Pref.register(d)
            d.set(false, forKey: Pref.soundOnCopy)
            d.set("system:NoSuchSound", forKey: Pref.sound)
            expect(!Chimes.shared.play(.copy, defaults: d))
        }
    },
]
