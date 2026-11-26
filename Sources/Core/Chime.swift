import Foundation

/// The confirmation sounds Mneme makes itself: short, soft tones built in code, so there is no audio file to ship.
public enum MadeSound: String, CaseIterable, Sendable {
    case drop, pluck, bell, tap

    public var name: String {
        switch self {
        case .drop: return "Drop"
        case .pluck: return "Pluck"
        case .bell: return "Bell"
        case .tap: return "Tap"
        }
    }

    /// 16-bit mono WAV at 44.1 kHz, peak just under full scale (the playback gain sets the loudness).
    public func wav() -> Data { wavData(samples()) }

    private static let rate = 44_100.0

    /// (frequency at time t, amplitude of each partial as a multiple of it, attack, decay time constant, length)
    private var shape: (pitch: (Double) -> Double, partials: [(ratio: Double, amp: Double, decay: Double)], attack: Double, length: Double) {
        switch self {
        case .drop:
            // A soft "bloop": the pitch rises quickly, like a drop landing.
            return ({ t in 420 * pow(980 / 420, min(t / 0.045, 1)) }, [(1, 1, 0.045), (2, 0.12, 0.03)], 0.003, 0.18)
        case .pluck:
            return ({ _ in 659.25 }, [(1, 1, 0.07), (2, 0.18, 0.045), (3, 0.05, 0.03)], 0.004, 0.26)
        case .bell:
            return ({ _ in 880 }, [(1, 1, 0.16), (2.76, 0.25, 0.08), (5.4, 0.08, 0.04)], 0.003, 0.52)
        case .tap:
            return ({ _ in 1250 }, [(1, 1, 0.014)], 0.0015, 0.07)
        }
    }

    func samples() -> [Double] {
        let s = shape
        let count = Int(s.length * Self.rate)
        let fadeOut = Int(0.01 * Self.rate)
        var phase = 0.0
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / Self.rate
            phase += 2 * .pi * s.pitch(t) / Self.rate
            var v = 0.0
            for p in s.partials { v += p.amp * sin(phase * p.ratio) * exp(-t / p.decay) }
            let attack = min(t / s.attack, 1)
            let tail = min(Double(count - 1 - i) / Double(fadeOut), 1)
            out[i] = v * attack * tail
        }
        let peak = out.map(abs).max() ?? 1
        return out.map { $0 / peak * 0.85 }
    }
}

func wavData(_ samples: [Double]) -> Data {
    var d = Data()
    func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 2)
    d.append(contentsOf: Array("RIFF".utf8)); put32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1); put32(44_100); put32(88_200); put16(2); put16(16)
    d.append(contentsOf: Array("data".utf8)); put32(bytes)
    d.reserveCapacity(d.count + Int(bytes))
    for s in samples { put16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32_767))) }
    return d
}

/// A saved sound choice is a made sound's raw value or "system:<name>" for one of the Mac's own sounds.
public func chimeSystemName(_ id: String) -> String? {
    id.hasPrefix("system:") ? String(id.dropFirst("system:".count)) : nil
}

/// The Mac's output level, in decibels, at which steady and plain playback sound the same (about half volume).
public let chimeReferenceDecibels = -20.0

/// The loudness slider (0...1) as the level the sound should be heard at, in decibels of the output's full scale.
public func chimeTargetDecibels(level: Double) -> Double {
    -50 + 36 * max(0, min(1, level))
}

/// The sound's own volume (0...1). Steady: set against the output's current level, so turning the Mac up makes
/// the sound quieter by the same amount and what is heard stays put; it can only fall short of the chosen level
/// when the Mac is turned down below it. Plain, or when the output has no level to read: a fixed volume that
/// rises and falls with the Mac's.
public func chimeGain(level: Double, steady: Bool, deviceDecibels: Double?) -> Double {
    let target = chimeTargetDecibels(level: level)
    let against = steady ? (deviceDecibels ?? chimeReferenceDecibels) : chimeReferenceDecibels
    return max(0, min(1, pow(10, (target - against) / 20)))
}

/// For outputs that report only a slider position: macOS's volume curve is close to the square of the position.
public func approxDecibels(fromScalar s: Double) -> Double? {
    s > 0 ? 40 * log10(min(s, 1)) : nil
}
