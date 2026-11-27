import CryptoKit
import Foundation

private func scratch() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("mneme-update-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

/// A tiny app bundle signed the way build.sh signs Mneme.
private func fakeApp(in dir: URL, id: String = "local.mneme", version: String, marker: String = "new") -> URL {
    let app = dir.appendingPathComponent("Mneme.app")
    let macos = app.appendingPathComponent("Contents/MacOS")
    try! FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": "Mneme",
                                "CFBundlePackageType": "APPL"]
    (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    try! FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appendingPathComponent("Mneme"))
    try! Data(marker.utf8).write(to: app.appendingPathComponent("Contents/Resources/marker"))
    _ = run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", id, app.path])
    return app
}

private func zipped(_ app: URL) -> Data {
    let zip = app.deletingLastPathComponent().appendingPathComponent("out.zip")
    _ = run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path])
    return try! Data(contentsOf: zip)
}

private func manifest(_ zip: Data, version: String, key: Curve25519.Signing.PrivateKey, url: URL = URL(string: "https://example.com/m.zip")!) -> UpdateManifest {
    try! signedManifest(zip: zip, version: version, build: 9, url: url, notes: "Notes", minimumSystem: "14.0",
                        privateKey: key.rawRepresentation.base64EncodedString())
}

private final class Box<T>: @unchecked Sendable { var value: T? }

private func wait<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = Box<T>(), done = DispatchSemaphore(value: 0)
    Task.detached { box.value = await body(); done.signal() }
    done.wait()
    return box.value!
}

private let mac14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)

let updateTests: [TestCase] = [
    test("should compare versions part by part as numbers") {
        expect(versionIsNewer("0.4", than: "0.3"))
        expect(versionIsNewer("0.10", than: "0.9"))
        expect(versionIsNewer("1.0", than: "0.99.9"))
        expect(versionIsNewer("0.4.1", than: "0.4"))
        expect(!versionIsNewer("0.4", than: "0.4.0"))
        expect(!versionIsNewer("0.3", than: "0.4"))
    },
    test("should offer only a newer version, for this Mac, over https, of a sane size") {
        let key = Curve25519.Signing.PrivateKey()
        let m = manifest(Data("zip".utf8), version: "0.5", key: key)
        expect(updateOffer(m, current: "0.4", system: mac14) == nil)
        expectEqual(updateOffer(m, current: "0.5", system: mac14), .notNewer)
        var later = m; later.minimumSystem = "15.0"
        expectEqual(updateOffer(later, current: "0.4", system: mac14), .needsNewerMac("15.0"))
        var older = m; older.minimumSystem = "13.5"
        expect(updateOffer(older, current: "0.4", system: mac14) == nil)
        var http = m; http.url = URL(string: "http://example.com/m.zip")!
        expectEqual(updateOffer(http, current: "0.4", system: mac14), .notHTTPS)
        var huge = m; huge.size = UpdateFeed.maxSize + 1
        expectEqual(updateOffer(huge, current: "0.4", system: mac14), .tooLarge)
    },
    test("should accept a zip signed with the release key and refuse a changed, cut or wrongly signed one") {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let zip = Data("the app".utf8)
        let m = manifest(zip, version: "0.5", key: key)
        expect(verifyUpdate(zip, manifest: m, publicKey: pub) == nil)
        expectEqual(verifyUpdate(Data("the apq".utf8), manifest: m, publicKey: pub), .wrongHash)
        expectEqual(verifyUpdate(Data("the ap".utf8), manifest: m, publicKey: pub), .wrongSize)
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        expectEqual(verifyUpdate(zip, manifest: m, publicKey: other), .badSignature, "signed with someone else's key")
        var forged = m; forged.signature = Data(repeating: 1, count: 64).base64EncodedString()
        expectEqual(verifyUpdate(zip, manifest: forged, publicKey: pub), .badSignature)
    },
    test("should refuse updates signed with any key but Mneme's own by default") {
        let zip = Data("the app".utf8)
        expectEqual(verifyUpdate(zip, manifest: manifest(zip, version: "0.5", key: Curve25519.Signing.PrivateKey())), .badSignature)
        expect(Data(base64Encoded: UpdateFeed.publicKey)?.count == 32, "the built-in key is a 32-byte Ed25519 key")
    },
    test("should read back the manifest a release writes") {
        let m = manifest(Data("z".utf8), version: "0.5", key: Curve25519.Signing.PrivateKey())
        let back = try JSONDecoder().decode(UpdateManifest.self, from: JSONEncoder().encode(m))
        expectEqual(back, m)
    },
    test("should unpack a signed Mneme of the promised version and refuse another app, version or a tampered one") {
        let dir = scratch()
        let good = zipped(fakeApp(in: dir.appendingPathComponent("a"), version: "0.5"))
        let staged = try UpdateInstaller.stage(zip: good, version: "0.5", root: dir.appendingPathComponent("stage"))
        expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/Info.plist").path))
        expect((try? UpdateInstaller.stage(zip: good, version: "0.6", root: dir.appendingPathComponent("s2"))) == nil, "not the promised version")
        let other = zipped(fakeApp(in: dir.appendingPathComponent("b"), id: "com.example.other", version: "0.5"))
        expect((try? UpdateInstaller.stage(zip: other, version: "0.5", root: dir.appendingPathComponent("s3"))) == nil, "not Mneme")
        let app = fakeApp(in: dir.appendingPathComponent("c"), version: "0.5")
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Mneme"))
        expectEqual(UpdateInstaller.check(app: app, version: "0.5"), .badSignature, "changed after signing")
        try? FileManager.default.removeItem(at: dir)
    },
    test("should swap the new app into place and remove the old one, or keep the old one when the new is missing") {
        let dir = scratch()
        let cur = fakeApp(in: dir.appendingPathComponent("Applications"), version: "0.4", marker: "old")
        let new = fakeApp(in: dir.appendingPathComponent("stage"), version: "0.5", marker: "new")
        let gone = "99999999"
        expectEqual(run("/bin/sh", ["-c", UpdateInstaller.swapScript, "swap", gone, cur.path, new.path, "0"]), 0)
        expectEqual(String(data: try Data(contentsOf: cur.appendingPathComponent("Contents/Resources/marker")), encoding: .utf8), "new")
        expect(!FileManager.default.fileExists(atPath: new.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: cur.deletingLastPathComponent().path)
        expectEqual(leftovers, ["Mneme.app"])
        expect(run("/bin/sh", ["-c", UpdateInstaller.swapScript, "swap", gone, cur.path, dir.appendingPathComponent("none.app").path, "0"]) != 0)
        expectEqual(String(data: try Data(contentsOf: cur.appendingPathComponent("Contents/Resources/marker")), encoding: .utf8), "new", "kept when the new app is missing")
        try? FileManager.default.removeItem(at: dir)
    },
    test("should say why Mneme cannot replace itself when it runs from a translocated or read-only place") {
        expect(Updater.cannotReplace(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Mneme.app")) != nil)
        expect(Updater.cannotReplace(URL(fileURLWithPath: "/System/Applications/Mneme.app")) != nil)
        expect(Updater.cannotReplace(scratch().appendingPathComponent("Mneme.app")) == nil)
    },
    test("should find a newer version in the feed, report up to date otherwise, and download, check and stage it") {
        let dir = scratch()
        let key = Curve25519.Signing.PrivateKey()
        let zip = zipped(fakeApp(in: dir.appendingPathComponent("a"), version: "0.5"))
        let zipURL = dir.appendingPathComponent("Mneme-0.5.zip")
        try zip.write(to: zipURL)
        var m = manifest(zip, version: "0.5", key: key)
        m.url = zipURL
        let feed = dir.appendingPathComponent("update.json")
        try JSONEncoder().encode(m).write(to: feed)
        let app = dir.appendingPathComponent("Applications/Mneme.app")
        // A file feed stands in for GitHub; the offer itself only allows https, so the found manifest is checked apart.
        let offered = wait { await Updater.fetch(feed: feed, current: "0.4", appURL: app) }
        if case .failed(let why) = offered { expectEqual(why, UpdateProblem.notHTTPS.message) } else { expect(false, "\(offered)") }
        let none = wait { await Updater.fetch(feed: feed, current: "0.5", appURL: app) }
        if case .upToDate = none {} else { expect(false, "\(none)") }
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let staged = wait { await Updater.download(m, appURL: app, publicKey: pub, stagingRoot: dir.appendingPathComponent("stage")) }
        if case .success(let url) = staged { expect(url.lastPathComponent == "Mneme.app") } else { expect(false, "\(staged)") }
        let refused = wait { await Updater.download(m, appURL: app, stagingRoot: dir.appendingPathComponent("stage2")) }
        if case .failure(let p) = refused { expectEqual(p, .badSignature) } else { expect(false, "a zip signed with another key was staged") }
        try? FileManager.default.removeItem(at: dir)
    },
]
