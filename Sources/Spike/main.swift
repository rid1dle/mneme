import AppKit
import ApplicationServices

/// Permission spike: proves what reading the clipboard costs in system alerts on this macOS.
///   (no flags)   log changeCount and accessBehavior every 0.5 s, never read contents
///   --types      also read the list of types once per change
///   --read       also read the plain text once per change
///   --phased     changes 1-2 count only, 3-4 read types, 5+ read text
///   --ax         print AXIsProcessTrusted() and quit
///   --seconds N  quit after N seconds (default 60)
@main
struct Spike {
    static func main() {
        let args = CommandLine.arguments
        let log = FileHandle(forWritingAtPath: "/tmp/mneme-spike.log") ?? {
            FileManager.default.createFile(atPath: "/tmp/mneme-spike.log", contents: nil)
            return FileHandle(forWritingAtPath: "/tmp/mneme-spike.log")!
        }()
        log.seekToEndOfFile()
        func say(_ s: String) {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
            FileHandle.standardOutput.write(line.data(using: .utf8)!)
            log.write(line.data(using: .utf8)!)
        }
        if args.contains("--ax") { say("ax trusted=\(AXIsProcessTrusted())"); return }
        let phased = args.contains("--phased")
        var changes = 0
        let typesFlag = args.contains("--types"), textFlag = args.contains("--read")
        let seconds = args.firstIndex(of: "--seconds").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 60
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let pb = NSPasteboard.general
        func behavior() -> String {
            guard #available(macOS 15.4, *) else { return "n/a" }
            switch pb.accessBehavior {
            case .default: return "default"
            case .ask: return "ask"
            case .alwaysAllow: return "alwaysAllow"
            case .alwaysDeny: return "alwaysDeny"
            @unknown default: return "unknown(\(pb.accessBehavior.rawValue))"
            }
        }
        var last = pb.changeCount
        say("start pid=\(getpid()) changeCount=\(last) behavior=\(behavior()) types=\(typesFlag) read=\(textFlag) phased=\(phased)")
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated {
            let now = pb.changeCount
            guard now != last else { return }
            last = now
            changes += 1
            let readTypes = phased ? changes >= 3 : typesFlag
            let readText = phased ? changes >= 5 : textFlag
            var line = "change#\(changes) changeCount=\(now) behavior=\(behavior())"
            if readTypes { line += " types=\((pb.types ?? []).map(\.rawValue).joined(separator: ","))" }
            if readText {
                let s = pb.string(forType: .string)
                line += " text=\(s.map { "\"\($0.prefix(40))\"" } ?? "nil") behaviorAfter=\(behavior())"
            }
            say(line)
        } }
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { say("stop behavior=\(behavior())"); exit(0) }
        app.run()
    }
}
