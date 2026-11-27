import CryptoKit
import Foundation

/// What a release publishes beside its zip as `update.json`. Every copy of Mneme reads the newest one to learn about
/// a newer version, then checks the zip it downloads against the size, hash and signature here.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public var version: String
    public var build: Int
    /// The zip holding Mneme.app.
    public var url: URL
    public var size: Int
    /// Hex SHA-256 of the zip.
    public var sha256: String
    /// Base64 Ed25519 signature of the zip's bytes, made with the release key.
    public var signature: String
    public var notes: String
    public var minimumSystem: String

    public init(version: String, build: Int, url: URL, size: Int, sha256: String, signature: String, notes: String, minimumSystem: String) {
        self.version = version; self.build = build; self.url = url; self.size = size; self.sha256 = sha256
        self.signature = signature; self.notes = notes; self.minimumSystem = minimumSystem
    }
}

public enum UpdateFeed {
    /// Always the newest release's manifest (GitHub serves the latest release's asset by name).
    public static let url = URL(string: "https://github.com/rid1dle/mneme/releases/latest/download/update.json")!
    /// The public half of the release key. Only zips signed with its private half are installed.
    public static let publicKey = "7CBClLsPpd0TMADjrIVeMsyYyizVEzMXzDuaCpaQy8M="
    /// A zip bigger than this is refused before it is downloaded.
    public static let maxSize = 100_000_000
}

/// True when `candidate` is a later version than `current`, comparing numbers part by part ("0.10" is after "0.9").
public func versionIsNewer(_ candidate: String, than current: String) -> Bool {
    func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
    let a = parts(candidate), b = parts(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

public enum UpdateProblem: Error, Equatable, Sendable {
    case notNewer, needsNewerMac(String), notHTTPS, tooLarge, wrongSize, wrongHash, badSignature

    public var message: String {
        switch self {
        case .notNewer: return "This version is already the newest."
        case .needsNewerMac(let v): return "The new version needs macOS \(v) or later."
        case .notHTTPS: return "The update's address is not secure."
        case .tooLarge: return "The update is larger than expected."
        case .wrongSize, .wrongHash: return "The download was damaged. Mneme will try again later."
        case .badSignature: return "The update is not signed by Mneme's release key, so it was not installed."
        }
    }
}

/// Whether a manifest is worth downloading on this Mac.
public func updateOffer(_ m: UpdateManifest, current: String, system: OperatingSystemVersion) -> UpdateProblem? {
    guard versionIsNewer(m.version, than: current) else { return .notNewer }
    let need = m.minimumSystem.split(separator: ".").map { Int($0) ?? 0 }
    let have = [system.majorVersion, system.minorVersion, system.patchVersion]
    for i in 0..<min(need.count, 3) where need[i] != have[i] {
        if need[i] > have[i] { return .needsNewerMac(m.minimumSystem) }
        break
    }
    guard m.url.scheme == "https" else { return .notHTTPS }
    guard m.size > 0, m.size <= UpdateFeed.maxSize else { return .tooLarge }
    return nil
}

/// Checks a downloaded zip against its manifest: size, hash, then the release key's signature.
public func verifyUpdate(_ zip: Data, manifest m: UpdateManifest, publicKey: String = UpdateFeed.publicKey) -> UpdateProblem? {
    guard zip.count == m.size else { return .wrongSize }
    guard sha256Hex(zip) == m.sha256.lowercased() else { return .wrongHash }
    guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
          let signature = Data(base64Encoded: m.signature), key.isValidSignature(signature, for: zip) else { return .badSignature }
    return nil
}

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The manifest for a zip, signed with the release key's private half (base64 raw Ed25519). Used by the release build.
public func signedManifest(zip: Data, version: String, build: Int, url: URL, notes: String, minimumSystem: String,
                           privateKey: String) throws -> UpdateManifest {
    guard let raw = Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw UpdateProblem.badSignature
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    return UpdateManifest(version: version, build: build, url: url, size: zip.count, sha256: sha256Hex(zip),
                          signature: try key.signature(for: zip).base64EncodedString(), notes: notes, minimumSystem: minimumSystem)
}
