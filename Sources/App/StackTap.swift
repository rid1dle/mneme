import AppKit

/// Sees ⌘V pressed in any app while the paste stack is on. The tap runs on its own thread with its own run loop, so
/// a busy main thread never holds up anyone's typing; `onCommandV` runs on that thread before the key reaches the
/// app (it must be quick and thread-safe), `onPasted` on the main thread after. Needs Accessibility (an active tap
/// that passes every event through unchanged). ⌘V presses Mneme posts itself are ignored.
final class StackTap: @unchecked Sendable {
    private let onCommandV: () -> Void
    private let onPasted: @MainActor () -> Void
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private var thread: Thread?

    init(onCommandV: @escaping () -> Void, onPasted: @escaping @MainActor () -> Void) {
        self.onCommandV = onCommandV
        self.onPasted = onPasted
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return tap != nil }

    /// False when macOS refused (no Accessibility).
    func start() -> Bool {
        if isRunning { return true }
        guard AXIsProcessTrusted() else { return false }
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        let t = Thread { [self] in
            let me = Unmanaged.passUnretained(self).toOpaque()
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<StackTap>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    me.reenable()
                    return Unmanaged.passUnretained(event)
                }
                let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
                if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 9, flags == .maskCommand,
                   event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                   event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) {
                    me.onCommandV()
                    DispatchQueue.main.async { MainActor.assumeIsolated { me.onPasted() } }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: me) else { ready.signal(); return }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            lock.lock(); tap = port; loop = CFRunLoopGetCurrent(); lock.unlock()
            ok = true
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "local.mneme.stack-tap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        return ok
    }

    func stop() {
        lock.lock()
        let (port, rl) = (tap, loop)
        tap = nil; loop = nil
        lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let rl { CFRunLoopStop(rl) }
        thread = nil
    }

    private func reenable() {
        lock.lock(); defer { lock.unlock() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}
