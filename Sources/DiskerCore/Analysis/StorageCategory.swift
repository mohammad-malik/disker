import Foundation

/// Buckets used for the chart legend and colouring.
///
/// Assigned by path rather than by file extension: on a full-volume scan the top-level
/// location tells you far more about what something is (and whether it is safe to touch)
/// than its suffix does.
public enum StorageCategory: String, Sendable, CaseIterable, Identifiable {
    case users = "Users"
    case applications = "Applications"
    case documents = "Documents"
    case media = "Media"
    case pictures = "Pictures"
    case developer = "Developer"
    case system = "System"
    case other = "Other"

    public var id: String { rawValue }

    /// SF Symbol shown in the centre of a large wedge.
    public var symbolName: String {
        switch self {
        case .users: return "folder.fill"
        case .applications: return "square.grid.2x2.fill"
        case .documents: return "doc.fill"
        case .media: return "music.note"
        case .pictures: return "photo.fill"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .system: return "gearshape.fill"
        case .other: return "ellipsis"
        }
    }

    /// Classifies a path. `relativeComponents` are the path components below the scan root.
    public static func classify(components: [String]) -> StorageCategory {
        guard let first = components.first else { return .other }

        switch first {
        case "Applications", "Applications (Parallels)":
            return .applications
        case "System", "Library", "usr", "bin", "sbin", "etc", "var", "private", "opt", "cores":
            return .system
        case "Users", "home":
            break  // Fall through: the interesting distinctions are one level deeper.
        default:
            return .other
        }

        // Inside a home directory: components are ["Users", <account>, <folder>, ...]
        guard components.count >= 3 else { return .users }
        switch components[2] {
        case "Documents", "Desktop", "Downloads":
            return .documents
        case "Pictures":
            return .pictures
        case "Music", "Movies":
            return .media
        case "Developer", "Projects", "Development", "src", "code":
            return .developer
        case "Library":
            return .system
        default:
            return .users
        }
    }

    /// Whether descending past `components` could still change the answer.
    ///
    /// Everything outside a home directory is decided by the first component alone, and
    /// inside one by the third. Past that point every descendant inherits its ancestor's
    /// category, which is what makes a full rollup affordable: the walk stops as soon as the
    /// classification is settled rather than visiting a volume's worth of nodes.
    static func canRefine(components: [String]) -> Bool {
        guard let first = components.first else { return true }
        guard first == "Users" || first == "home" else { return false }
        return components.count < 3
    }

    /// Bytes per category beneath `root`, counted once each.
    ///
    /// The legend used to classify only the charted folder's *direct children*, which made it
    /// disagree with the chart as soon as you drilled in: inside `Users` every child is
    /// `Users/<account>`, so the whole legend collapsed to one entry reading "Users" while
    /// the rings below it were drawn in five colours the legend never mentioned.
    ///
    /// Sizes are attributed at the depth where the category is actually decided, and a
    /// folder only contributes the bytes that are not already inside a child — so a subtree
    /// whose category differs from its parent's is counted under its own colour and nowhere
    /// else, and the totals still add up to the root.
    public static func totals(
        for root: FileNode, rootComponents: [String] = []
    ) -> [CategoryTotal] {
        var sums: [StorageCategory: UInt64] = [:]

        func walk(_ node: FileNode, components: [String]) {
            let category = classify(components: components)
            guard canRefine(components: components), !node.children.isEmpty else {
                sums[category, default: 0] &+= node.size
                return
            }
            var inChildren: UInt64 = 0
            for child in node.children {
                walk(child, components: components + [child.name])
                inChildren &+= child.size
            }
            // Whatever sits directly in this folder rather than in one of its children.
            if node.size > inChildren {
                sums[category, default: 0] &+= node.size - inChildren
            }
        }

        for child in root.children {
            walk(child, components: rootComponents + [child.name])
        }
        return sums
            .map { CategoryTotal(category: $0.key, size: $0.value) }
            .sorted { $0.size > $1.size }
    }
}

/// One legend entry: a category and how much of the charted folder it accounts for.
public struct CategoryTotal: Sendable, Identifiable, Equatable {
    public let category: StorageCategory
    public let size: UInt64

    public var id: StorageCategory { category }

    public init(category: StorageCategory, size: UInt64) {
        self.category = category
        self.size = size
    }
}
