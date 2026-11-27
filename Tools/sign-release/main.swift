import Foundation

// sign-release <zip> <version> <build> <download url> <minimum macOS> [notes file]
// Reads the release key (base64 raw Ed25519) from MNEME_UPDATE_KEY and prints update.json. Refuses a key whose public
// half is not the one built into Mneme, since copies of Mneme would refuse its updates.
let a = CommandLine.arguments
guard a.count >= 6, let build = Int(a[3]), let url = URL(string: a[4]) else {
    FileHandle.standardError.write("usage: sign-release <zip> <version> <build> <url> <minimum macOS> [notes file]\n".data(using: .utf8)!)
    exit(2)
}
guard let key = ProcessInfo.processInfo.environment["MNEME_UPDATE_KEY"], !key.isEmpty else {
    FileHandle.standardError.write("MNEME_UPDATE_KEY is not set\n".data(using: .utf8)!)
    exit(2)
}
do {
    let zip = try Data(contentsOf: URL(fileURLWithPath: a[1]))
    let notes = a.count > 6 ? (try String(contentsOfFile: a[6], encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let m = try signedManifest(zip: zip, version: a[2], build: build, url: url, notes: notes, minimumSystem: a[5], privateKey: key)
    if let p = verifyUpdate(zip, manifest: m) {
        FileHandle.standardError.write("the key does not match Mneme's built-in public key (\(p))\n".data(using: .utf8)!)
        exit(1)
    }
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try e.encode(m) + Data("\n".utf8))
} catch {
    FileHandle.standardError.write("sign-release: \(error)\n".data(using: .utf8)!)
    exit(1)
}
