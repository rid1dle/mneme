import Foundation

/// Copies collected while the stack is on, pasted back one at a time in the order they were copied.
public struct PasteStack: Equatable {
    public private(set) var items: [UUID] = []
    public private(set) var isOn = false
    public init() {}

    public var remaining: Int { items.count }

    public mutating func start() { items = []; isOn = true }
    public mutating func stop() { items = []; isOn = false }

    public mutating func add(_ id: UUID) {
        guard isOn else { return }
        items.removeAll { $0 == id }
        items.append(id)
    }

    /// Taken out by the user; the stack stays on so more can be copied.
    public mutating func remove(_ id: UUID) { items.removeAll { $0 == id } }

    /// Reorders, with the same offsets as `Array.move(fromOffsets:toOffset:)` (what a dragged list row reports).
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().filter(items.indices.contains).map { items[$0] }
        let before = source.filter { $0 < destination }.count
        items = items.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        items.insert(contentsOf: moving, at: min(max(destination - before, 0), items.count))
    }

    /// The oldest stacked item; the stack turns itself off when this was the last one.
    public mutating func next() -> UUID? {
        guard isOn, !items.isEmpty else { return nil }
        let id = items.removeFirst()
        if items.isEmpty { isOn = false }
        return id
    }
}
