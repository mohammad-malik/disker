import Foundation

public struct MoleItem: Sendable, Identifiable {
    public let id = UUID()
    public let name: String
    public let size: UInt64

    public init(name: String, size: UInt64) {
        self.name = name
        self.size = size
    }
}

public struct MoleCategory: Sendable, Identifiable {
    public let id = UUID()
    public let name: String
    public let items: [MoleItem]

    public var totalSize: UInt64 { items.reduce(0) { $0 &+ $1.size } }

    public init(name: String, items: [MoleItem]) {
        self.name = name
        self.items = items
    }
}

/// Outcome of a Mole dry run.
///
/// `unparseable` is a first-class result rather than an error because Mole's output is a
/// human-facing TUI, not a stable API. If a future version changes its formatting, showing
/// "couldn't read Mole's output" is correct; inventing a reclaimable-space figure from a
/// half-matched parse would be worse than showing nothing, since the number drives a
/// destructive decision.
public enum MoleReport: Sendable {
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
