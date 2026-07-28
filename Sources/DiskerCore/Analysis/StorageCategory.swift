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
}
