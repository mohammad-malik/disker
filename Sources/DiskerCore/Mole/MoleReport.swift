import Foundation

public struct MoleItem: Sendable, Identifiable, Codable {
    public let id = UUID()
    public let name: String
    public let size: UInt64

    public init(name: String, size: UInt64) {
        self.name = name
        self.size = size
    }

    /// `id` is a fresh identity for SwiftUI's benefit, not part of the data, so it is left
    /// out of the encoding. It also could not be decoded into a `let` that already has an
    /// initialiser — listing it here would only produce a warning and a useless field.
    private enum CodingKeys: String, CodingKey {
        case name, size
    }
}

public struct MoleCategory: Sendable, Identifiable, Codable {
    public let id = UUID()
    public let name: String
    public let items: [MoleItem]

    public var totalSize: UInt64 { items.reduce(0) { $0 &+ $1.size } }

    public init(name: String, items: [MoleItem]) {
        self.name = name
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case name, items
    }
}

/// Outcome of a Mole dry run.
///
/// `unparseable` is a first-class result rather than an error because Mole's output is a
/// human-facing TUI, not a stable API. If a future version changes its formatting, showing
/// "couldn't read Mole's output" is correct; inventing a reclaimable-space figure from a
/// half-matched parse would be worse than showing nothing, since the number drives a
/// destructive decision.
public enum MoleReport: Sendable, Codable {
    case parsed(categories: [MoleCategory], totalReclaimable: UInt64)
    case unparseable(reason: String)

    public var categories: [MoleCategory] {
        if case .parsed(let categories, _) = self { return categories }
        return []
    }

    public var totalReclaimable: UInt64 {
        if case .parsed(_, let total) = self { return total }
        return 0
    }
}
