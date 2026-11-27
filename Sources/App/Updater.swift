import AppKit

/// Keeps Mneme up to date from its GitHub releases: checks `update.json` at launch and every six hours, downloads a
/// newer version, checks its size, hash and release-key signature, unpacks and checks the app inside, then swaps it in
/// and reopens it (on its own while Mneme is idle when automatic updates are on, else when asked).
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate
        case downloading(String)
        /// Downloaded, checked and unpacked: installs on the next idle moment, or when asked.
        case ready(UpdateManifest)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    let current: String
    /// True while a restart would interrupt the user (the shelf is open, the paste stack is on).
    var isBusy: () -> Bool = { false }

    private let defaults: UserDefaults
    private let feed: URL
    private let appURL: URL
    private var staged: URL?
    private var timers: [Timer] = []

    init(defaults: UserDefaults = .standard, appURL: URL = Bundle.main.bundleURL,
         current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.defaults = defaults
        self.appURL = appURL
        self.current = current
        feed = defaults.string(forKey: Pref.updateFeed).flatMap(URL.init(string:)) ?? UpdateFeed.url
        lastChecked = defaults.object(forKey: Pref.updateLastChecked) as? Date
    }

    /// Starts the checks. Returns the version Mneme was just updated from, if it was.
    @discardableResult
    func start() -> String? {
        let previous = defaults.string(forKey: Pref.lastRunVersion)
        defaults.set(current, forKey: Pref.lastRunVersion)
        timers = [
            Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.check() } },
            Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.installIfIdle() } },
        ]
        return previous.flatMap { versionIsNewer(current, than: $0) ? $0 : nil }
    }

    /// Where Mneme cannot replace itself, the reason in words.
    var cannotUpdate: String? { Self.cannotReplace(appURL) }

    nonisolated static func cannotReplace(_ app: URL) -> String? {
        if app.path.contains("/AppTranslocation/") { return "Move Mneme to your Applications folder to get updates." }
        if !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return "Mneme cannot replace itself in \(app.deletingLastPathComponent().path). Move it to your Applications folder."
        }
        return nil
    }

    func check(manual: Bool = false) {
        switch state {
        case .checking, .downloading: return
        case .ready: if !manual { return }
        default: break
        }
        if let why = cannotUpdate { state = .failed(why); return }
        state = .checking
        Task {
            let result = await Self.fetch(feed: feed, current: current, appURL: appURL)
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Pref.updateLastChecked)
            switch result {
            case .upToDate: state = .upToDate
            case .failed(let why): state = manual ? .failed(why) : .idle
            case .found(let m):
                state = .downloading(m.version)
                switch await Self.download(m, appURL: appURL) {
                case .success(let app):
                    staged = app
                    state = .ready(m)
                    installIfIdle()
                case .failure(let p): state = .failed(p.message)
                }
            }
        }
    }

    /// Installs a downloaded update when automatic updates are on and Mneme is not in use.
    func installIfIdle() {
        guard case .ready = state, defaults.bool(forKey: Pref.autoUpdate), !isBusy() else { return }
        installNow()
    }

    /// Swaps the new app in after Mneme quits, then opens it.
    func installNow() {
        guard case .ready(let m) = state, let staged else { return }
        do {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", UpdateInstaller.swapScript, "swap", String(ProcessInfo.processInfo.processIdentifier), appURL.path, staged.path, "1"]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("Could not install \(m.version): \(error.localizedDescription)")
        }
    }

    // MARK: off the main thread

    enum Fetched: Sendable { case upToDate, found(UpdateManifest), failed(String) }

    nonisolated static func fetch(feed: URL, current: String, appURL: URL) async -> Fetched {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Mneme/\(current)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) as (Data, URLResponse) else {
            return .failed("Could not reach the update server. Check your connection.")
        }
        // No release publishes update.json yet: nothing to offer.
        if (response as? HTTPURLResponse)?.statusCode == 404 { return .upToDate }
        guard let m = try? JSONDecoder().decode(UpdateManifest.self, from: data) else {
            return .failed("The update information could not be read.")
        }
        switch updateOffer(m, current: current, system: ProcessInfo.processInfo.operatingSystemVersion) {
        case nil: return .found(m)
        case .notNewer: return .upToDate
        case let p?: return .failed(p.message)
        }
    }

    nonisolated static func download(_ m: UpdateManifest, appURL: URL, publicKey: String = UpdateFeed.publicKey,
                                     stagingRoot: URL? = nil) async -> Result<URL, UpdateProblem> {
        guard let (data, _) = try? await URLSession.shared.data(from: m.url) as (Data, URLResponse) else { return .failure(.wrongSize) }
        if let p = verifyUpdate(data, manifest: m, publicKey: publicKey) { return .failure(p) }
        do {
            return .success(try UpdateInstaller.stage(zip: data, version: m.version, root: stagingRoot))
        } catch let p as UpdateProblem {
            return .failure(p)
        } catch {
            return .failure(.wrongHash)
        }
    }
}

/// Unpacking, checking and swapping, apart from the app so tests can run them on scratch folders.
enum UpdateInstaller {
    static let bundleID = "local.mneme"

    /// Unpacks a verified zip into Caches and checks the app inside. Returns the app.
    static func stage(zip: Data, version: String, root: URL? = nil) throws -> URL {
        let base = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID).appendingPathComponent("Update")
        let dir = base.appendingPathComponent(version)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("update.zip")
        try zip.write(to: zipURL)
        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, dir.path])
        try? FileManager.default.removeItem(at: zipURL)
        let app = dir.appendingPathComponent("Mneme.app")
        if let p = check(app: app, version: version) { throw p }
        return app
    }

    /// The app is Mneme, is the promised version, and its signature holds.
    static func check(app: URL, version: String) -> UpdateProblem? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == version else { return .wrongHash }
        return (try? run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])) == nil ? .badSignature : nil
    }

    /// `sh -c swapScript swap <pid> <current app> <new app> <reopen 1|0>`: waits up to ten seconds for Mneme to quit,
    /// moves the new app into place (putting the old one back if that fails), then reopens it.
    static let swapScript = """
    pid=$1; cur=$2; new=$3; reopen=$4
    i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
    old="$cur.old-$$"
    if mv "$cur" "$old"; then
      if mv "$new" "$cur"; then rm -rf "$old"; else mv "$old" "$cur"; exit 1; fi
    else exit 1; fi
    xattr -dr com.apple.quarantine "$cur" 2>/dev/null
    [ "$reopen" = 1 ] && open "$cur"
    exit 0
    """

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateProblem.wrongHash }
        return p.terminationStatus
    }
}
