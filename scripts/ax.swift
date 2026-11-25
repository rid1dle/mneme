// A tiny accessibility driver for testing the live app, built with: swiftc -O -o build/ax scripts/ax.swift
//   ax <pid> dump                 print the window's elements (role, identifier, title, value)
//   ax <pid> press <name>         press the first element whose identifier, title or description matches
//   ax <pid> find <name>          print matching elements and exit 1 when none
//   ax <pid> type <name> <text>   set a text field's value (search box)
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    print("usage: ax <pid> dump|press|find|type ..."); exit(2)
}
guard AXIsProcessTrusted() else { print("accessibility permission missing"); exit(3) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ name: String) -> String {
    guard let v = attr(e, name) else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

func walk(_ e: AXUIElement, depth: Int = 0, _ visit: (AXUIElement, Int) -> Bool) -> Bool {
    if visit(e, depth) { return true }
    guard depth < 40 else { return false }
    for c in children(e) { if walk(c, depth: depth + 1, visit) { return true } }
    return false
}

func describe(_ e: AXUIElement) -> String {
    let parts = [str(e, kAXRoleAttribute), "id=" + str(e, kAXIdentifierAttribute), "title=" + str(e, kAXTitleAttribute),
                 "desc=" + str(e, kAXDescriptionAttribute), "value=" + str(e, kAXValueAttribute)]
    return parts.filter { !$0.hasSuffix("=") }.joined(separator: " ")
}

func matches(_ e: AXUIElement, _ name: String) -> Bool {
    [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains { str(e, $0) == name }
}

let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard let window = windows.first(where: { str($0, kAXTitleAttribute) == "Kenosis" }) ?? windows.first else { print("no window"); exit(4) }

switch args[2] {
case "dump":
    _ = walk(window) { e, d in print(String(repeating: "  ", count: d) + describe(e)); return false }
case "find":
    var found = 0
    _ = walk(window) { e, _ in if matches(e, args[3]) { print(describe(e)); found += 1 }; return false }
    exit(found > 0 ? 0 : 1)
case "press":
    var done = false
    _ = walk(window) { e, _ in
        guard matches(e, args[3]) else { return false }
        done = AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
        return done
    }
    print(done ? "pressed \(args[3])" : "not found: \(args[3])")
    exit(done ? 0 : 1)
case "type":
    var done = false
    _ = walk(window) { e, _ in
        guard matches(e, args[3]) || (str(e, kAXRoleAttribute) == "AXTextField" && str(e, kAXDescriptionAttribute) == args[3]) else { return false }
        done = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, args[4] as CFTypeRef) == .success
        return done
    }
    print(done ? "typed" : "not found: \(args[3])")
    exit(done ? 0 : 1)
case "open":
    // Select the row holding the named element, then press Return in the app.
    var done = false
    var lastRow: AXUIElement?
    _ = walk(window) { e, _ in
        if str(e, kAXRoleAttribute) == "AXRow" { lastRow = e }
        guard matches(e, args[3]), let row = lastRow else { return false }
        if let table = attr(row, kAXParentAttribute) {
            AXUIElementSetAttributeValue(table as! AXUIElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        done = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
        return done
    }
    guard done else { print("not found: \(args[3])"); exit(1) }
    usleep(200_000)
    for down in [true, false] {
        CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: down)?.postToPid(pid)
    }
    print("opened \(args[3])")
case "search":
    var done = false
    _ = walk(window) { e, _ in
        guard str(e, kAXRoleAttribute) == "AXTextField" else { return false }
        done = AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        return done
    }
    usleep(200_000)
    // Real keystrokes: SwiftUI only sees typed text, not a value set through accessibility.
    for ch in args[3].utf16 {
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            var c = ch
            ev?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            ev?.postToPid(pid)
        }
        usleep(30_000)
    }
    print(done ? "searched \(args[3])" : "no search field")
    exit(done ? 0 : 1)
case "menu":
    // Open a pop-up/menu button by name, then press the menu item titled args[4].
    var opened = false
    _ = walk(window) { e, _ in
        guard matches(e, args[3]) else { return false }
        // A split button keeps its menu on a separate arrow (AXMenuButton) inside it.
        if let arrow = children(e).first(where: { str($0, kAXRoleAttribute) == "AXMenuButton" }) {
            opened = AXUIElementPerformAction(arrow, kAXPressAction as CFString) == .success
        } else {
            opened = AXUIElementPerformAction(e, kAXShowMenuAction as CFString) == .success
        }
        return opened
    }
    guard opened else { print("no menu: \(args[3])"); exit(1) }
    usleep(400_000)
    var pressed = false
    _ = walk(app) { e, _ in
        guard str(e, kAXRoleAttribute) == "AXMenuItem", str(e, kAXTitleAttribute) == args[4] else { return false }
        pressed = AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
        return pressed
    }
    print(pressed ? "chose \(args[4])" : "no item: \(args[4])")
    exit(pressed ? 0 : 1)
case "context":
    // Right-click menu of the element named args[3], then press the item titled args[4].
    var opened = false
    _ = walk(window) { e, _ in
        guard matches(e, args[3]) else { return false }
        var cur: AXUIElement? = e
        for _ in 0..<4 {
            guard let c = cur else { break }
            if AXUIElementPerformAction(c, kAXShowMenuAction as CFString) == .success { opened = true; break }
            cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        return opened
    }
    guard opened else { print("no context menu: \(args[3])"); exit(1) }
    usleep(400_000)
    var pressed = false
    _ = walk(app) { e, _ in
        guard str(e, kAXRoleAttribute) == "AXMenuItem", str(e, kAXTitleAttribute) == args[4] else { return false }
        pressed = AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
        return pressed
    }
    print(pressed ? "chose \(args[4])" : "no item: \(args[4])")
    exit(pressed ? 0 : 1)
case "sheet":
    // Press a button in any sheet or dialog of the app (confirmation dialogs).
    var pressed = false
    for w in windows {
        _ = walk(w) { e, _ in
            guard str(e, kAXRoleAttribute) == "AXButton", str(e, kAXTitleAttribute) == args[3] || str(e, kAXDescriptionAttribute) == args[3] else { return false }
            pressed = AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
            return pressed
        }
        if pressed { break }
    }
    print(pressed ? "pressed \(args[3])" : "no button: \(args[3])")
    exit(pressed ? 0 : 1)
default:
    print("unknown command"); exit(2)
}
