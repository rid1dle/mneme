import Foundation

/// Decides what is on the clipboard while the paste stack runs. Called from the key watcher's thread on every ⌘V and
/// from the main thread for the delayed switch, so it is locked.
///
/// After a ⌘V the next item goes on the clipboard a moment later (the app reads it first). If another ⌘V comes before
/// that, the switch happens at once, before that ⌘V reaches the app, so two quick presses paste two items.
final class StackRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var upcoming: [[Representation]] = []
    private var owed = false
    private let write: ([Representation]) -> Void

    init(write: @escaping ([Representation]) -> Void) { self.write = write }

    /// What comes after the item that is on the clipboard now, in order.
    func setUpcoming(_ items: [[Representation]]) {
        lock.lock(); defer { lock.unlock() }
        upcoming = items
    }

    /// A ⌘V was pressed (it pastes whatever is on the clipboard now).
    func commandV() {
        lock.lock(); defer { lock.unlock() }
        if owed, !upcoming.isEmpty { write(upcoming.removeFirst()) }
        owed = true
    }

    /// The delayed switch: puts the next item on if a ⌘V used the current one.
    func flush() {
        lock.lock(); defer { lock.unlock() }
        guard owed else { return }
        owed = false
        if !upcoming.isEmpty { write(upcoming.removeFirst()) }
    }

    var remaining: Int { lock.lock(); defer { lock.unlock() }; return upcoming.count }
}
