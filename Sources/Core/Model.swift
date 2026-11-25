import Foundation

public enum ItemKind: String, CaseIterable, Codable, Sendable {
    case text, richText, image, file, link, color
}

/// One pasteboard type's bytes. `index` is the pasteboard item it belongs to (several files are several items).
public struct Representation: Equatable, Sendable {
    public let index: Int
    public let type: String
    public let data: Data
    public init(index: Int = 0, type: String, data: Data) { self.index = index; self.type = type; self.data = data }
}

public struct SourceApp: Equatable, Hashable, Sendable {
    public let bundleID: String
    public let name: String
    public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
}

public struct Item: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: ItemKind
    public var title: String?
    public var text: String?
    public var preview: String
    public var hash: String
    public var byteSize: Int
    public var charCount: Int
    public var source: SourceApp?
    public var fileURLs: [URL]
    public var linkTitle: String?
    public var linkImage: String?
    public var ocrText: String?
    public var thumb: String?
    public var width: Int?
    public var height: Int?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date
    public var inHistory: Bool
    public var deletedAt: Date?
}

public struct Pinboard: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// #RRGGBB
    public var color: String
    public var order: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
}
