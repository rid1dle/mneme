import AppKit

private let richCopy = "<p style=\"color: rgb(248,248,242); background-color: rgb(33,34,44)\">Plan:</p><ul style=\"color: rgb(248,248,242)\"><li><strong>one</strong></li><li>two</li></ul>"

private struct Rig {
    let pb = NSPasteboard(name: NSPasteboard.Name("mneme-test-\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "mneme-format-\(UUID().uuidString)")!
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("mneme-paste-log-\(UUID().uuidString).jsonl")
    let formatter: PasteFormatter

    init() {
        Pref.register(defaults)
        formatter = PasteFormatter(pasteboard: pb, defaults: defaults, logURL: log)
    }

    /// Puts a copy on the pasteboard the way an app would, and tells the formatter as the watcher does.
    @discardableResult
    func copy(_ reps: [Representation], from source: String?) -> Int {
        pb.clearContents()
        let item = NSPasteboardItem()
        for r in reps { item.setData(r.data, forType: NSPasteboard.PasteboardType(r.type)) }
        pb.writeObjects([item])
        formatter.copied(reps, source: source.map { SourceApp(bundleID: $0, name: $0) }, changeCount: pb.changeCount)
        formatter.settle()
        return pb.changeCount
    }

    func press(into bundle: String) {
        formatter.setFront(bundle: bundle, name: bundle, pid: 0)
        formatter.commandV()
    }

    var types: Set<String> { Set((pb.types ?? []).map(\.rawValue)) }
    func string(_ t: String) -> String? { pb.string(forType: NSPasteboard.PasteboardType(t)) }
}

private func rich() -> [Representation] {
    [Representation(type: PasteType.html, data: Data(richCopy.utf8)), Representation(type: PasteType.plain, data: Data("Plan:\none\ntwo".utf8)),
     Representation(type: "org.chromium.source-url", data: Data("{}".utf8))]
}

let pasteFormatterTests: [TestCase] = [
    test("should give each app its own form of one copy as ⌘V goes to mail, a spreadsheet, a terminal and back") {
        let r = Rig()
        r.copy(rich(), from: "com.microsoft.VSCode")
        r.press(into: "com.apple.mail")
        expect(r.string(PasteType.html)?.contains("rgb(") == false, "mail gets no theme colours")
        expect(r.string(PasteType.html)?.contains("<ul><li><strong>one</strong></li>") == true, r.string(PasteType.html) ?? "")
        expect(!r.types.contains("org.chromium.source-url"))
        r.press(into: "com.microsoft.Excel")
        expectEqual(r.string(PasteType.html), richCopy, "the spreadsheet gets the original")
        r.press(into: "com.apple.Terminal")
        expectEqual(r.string(PasteType.plain), "Plan:\n\n- one\n- two")
        expect(!r.types.contains(PasteType.html))
        r.press(into: "net.whatsapp.WhatsApp")
        expectEqual(r.string(PasteType.plain), "Plan:\n\n• one\n• two", "a chat gets dots, not the terminal's dashes")
        r.press(into: "com.microsoft.VSCode")
        expect(r.types.contains("org.chromium.source-url"), "back home it is the original, private types included")
    },
    test("should mark its rewrites as Mneme's own so they are not stored again") {
        let r = Rig()
        r.copy(rich(), from: "com.microsoft.VSCode")
        r.press(into: "com.apple.mail")
        expect(r.types.contains(ownMarkerType))
    },
    test("should not rewrite the clipboard when the app already has the right form") {
        let r = Rig()
        let count = r.copy(rich(), from: "com.microsoft.VSCode")
        r.press(into: "com.microsoft.Excel")
        expectEqual(r.pb.changeCount, count)
    },
    test("should leave the clipboard alone when ⌘V formatting is off") {
        let r = Rig()
        r.defaults.set(false, forKey: Pref.formatOnCommandV)
        let count = r.copy(rich(), from: "com.microsoft.VSCode")
        r.press(into: "com.apple.mail")
        expectEqual(r.pb.changeCount, count)
    },
    test("should never touch a newer copy it has not seen") {
        let r = Rig()
        r.copy(rich(), from: "com.microsoft.VSCode")
        r.pb.clearContents()
        r.pb.setString("someone else's copy", forType: .string)
        let count = r.pb.changeCount
        r.press(into: "com.apple.Terminal")
        expectEqual(r.pb.changeCount, count)
        expectEqual(r.pb.string(forType: .string), "someone else's copy")
    },
    test("should leave a spreadsheet's copy and plain prose exactly as copied") {
        let r = Rig()
        let sheet = r.copy([Representation(type: PasteType.html, data: Data("<table><tr><td style=\"background:#ff0\">1</td></tr></table>".utf8)),
                            Representation(type: PasteType.plain, data: Data("1".utf8))], from: "com.microsoft.Excel")
        r.press(into: "com.apple.mail")
        expectEqual(r.pb.changeCount, sheet)
        let prose = r.copy([Representation(type: PasteType.plain, data: Data("see you at 5".utf8))], from: "com.apple.Notes")
        r.press(into: "com.apple.mail")
        expectEqual(r.pb.changeCount, prose)
    },
    test("should paste Markdown from a terminal as formatting into mail and as written into an editor") {
        let r = Rig()
        r.copy([Representation(type: PasteType.plain, data: Data("Steps:\n- **build**\n- test".utf8))], from: "com.apple.Terminal")
        r.press(into: "com.apple.mail")
        expectEqual(r.string(PasteType.html), "<p>Steps:</p><ul><li><strong>build</strong></li><li>test</li></ul>")
        r.press(into: "com.microsoft.VSCode")
        expectEqual(r.string(PasteType.plain), "Steps:\n- **build**\n- test")
    },
    test("should paste plain text on the shortcut and learn it for that place after the second time") {
        let r = Rig()
        r.copy(rich(), from: "com.microsoft.VSCode")
        expect(r.formatter.takeNow(.plain, targetBundle: "com.apple.mail", targetName: "Mail", pid: 0))
        expect(r.types.contains(PasteType.plain) && !r.types.contains(PasteType.html), "\(r.types)")
        r.press(into: "com.apple.mail")
        expect(r.types.contains(PasteType.html), "one choice is not a rule yet: ⌘V gives clean again")
        expect(r.formatter.takeNow(.plain, targetBundle: "com.apple.mail", targetName: "Mail", pid: 0))
        r.press(into: "com.apple.Notes")
        r.press(into: "com.apple.mail")
        expect(!r.types.contains(PasteType.html), "learned: mail now gets plain text on ⌘V")
        expectEqual(r.formatter.learnedRules.map(\.name), ["com.microsoft.VSCode to Mail"])
        let saved = r.defaults.data(forKey: Pref.pasteLearning).flatMap { try? JSONDecoder().decode(PasteLearning.self, from: $0) }
        expectEqual(saved?.version(for: PastePlace(sourceBundle: "com.microsoft.VSCode", targetBundle: "com.apple.mail").learningKey), .plain, "kept across launches")
        r.formatter.forget(nil)
        expect(r.formatter.learnedRules.isEmpty)
    },
    test("should paste the original on the shortcut even where the rule says clean") {
        let r = Rig()
        r.copy(rich(), from: "com.microsoft.VSCode")
        r.press(into: "com.apple.mail")
        expect(r.formatter.takeNow(.original, targetBundle: "com.apple.mail", targetName: "Mail", pid: 0))
        expectEqual(r.string(PasteType.html), richCopy)
    },
    test("should read a copy it never saw when a shortcut asks for it") {
        let r = Rig()
        r.pb.clearContents()
        r.pb.setString("<b>x</b>", forType: .html)
        r.pb.setString("x", forType: .string)
        expect(r.formatter.takeNow(.plain, targetBundle: "com.apple.mail", targetName: "Mail", pid: 0))
        expectEqual(r.pb.string(forType: .string), "x")
        expect(r.pb.string(forType: .html) == nil)
    },
    test("should refuse plain text for a copy with no text and leave it on the clipboard") {
        let r = Rig()
        let count = r.copy([Representation(type: PasteType.png, data: Data([1, 2, 3]))], from: "com.apple.Preview")
        expect(!r.formatter.takeNow(.plain, targetBundle: "com.apple.mail", targetName: "Mail", pid: 0))
        expectEqual(r.pb.changeCount, count)
    },
    test("should log each paste's apps, form and reason, and never its content") {
        let r = Rig()
        r.copy(rich(), from: "com.microsoft.VSCode")
        r.press(into: "com.apple.mail")
        r.formatter.settle()
        let log = (try? String(contentsOf: r.log, encoding: .utf8)) ?? ""
        expect(log.contains("\"target\":\"com.apple.mail\"") && log.contains("\"version\":\"clean\"") && log.contains("\"reason\":\"rule\""), log)
        expect(!log.contains("Plan") && !log.contains("one"), "no content in the log")
        try? FileManager.default.removeItem(at: r.log)
    },
    test("should put an item copied from the shelf as copied, ready for ⌘V elsewhere") {
        MainActor.assumeIsolated {
            let r = Rig()
            let count = r.formatter.put(rich(), text: "Plan:\none\ntwo", source: SourceApp(bundleID: "com.microsoft.VSCode", name: "Code"), target: nil, as: nil)
            expectEqual(count, r.pb.changeCount)
            expectEqual(r.string(PasteType.html), richCopy)
            r.press(into: "com.apple.Terminal")
            expectEqual(r.string(PasteType.plain), "Plan:\n\n- one\n- two")
        }
    },
]
