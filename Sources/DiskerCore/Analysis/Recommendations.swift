import Foundation

public struct Recommendation: Sendable, Identifiable {
    public let id = UUID()
    public let title: String
    public let detail: String
    public let path: String
    public let size: UInt64
    public let tier: Tier
    public let symbolName: String

    /// Location with the home directory abbreviated to `~`.
    ///
    /// Needed because titles collide constantly in practice — a real scan turned up three
    /// separate "node_modules in frontend" entries. Without the location there is no way to
    /// tell which one is about to be deleted.
    ///
    /// Stored rather than computed: a full scan produces well over a thousand of these, and
    /// as a computed property it re-ran `NSHomeDirectory()` plus string manipulation for
    /// every row on every render pass.
    public let displayPath: String

    init(
        title: String, detail: String, path: String, size: UInt64,
        tier: Tier, symbolName: String
    ) {
        self.title = title
        self.detail = detail
        self.path = path
        self.size = size
        self.tier = tier
        self.symbolName = symbolName

        let home = NSHomeDirectory()
        let parent = (path as NSString).deletingLastPathComponent
        self.displayPath =
            parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }

    /// How much scrutiny an item deserves before deletion.
    ///
    /// Nothing is ever removed automatically regardless of tier — the tier decides how the
    /// UI presents it, not whether Disker acts on it.
    public enum Tier: Int, Sendable, Comparable {
        /// Regenerated on demand. Removing it costs time, never data.
        case safe = 0
        /// Probably unwanted, but it is the user's own content and only they can say.
        case review = 1
        /// Worth knowing about; no action implied.
        case informational = 2

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .safe: return "Safe to remove"
            case .review: return "Review first"
            case .informational: return "Worth knowing"
            }
        }
    }
}

/// Derives cleanup suggestions from an already-scanned tree.
///
/// Works entirely from the in-memory tree rather than re-walking the disk, so producing
/// suggestions costs nothing on top of the scan the user already waited for.
/// Recommendations grouped by tier, with totals, computed once.
///
/// The view used to derive this on every body evaluation — filtering the whole list per tier
/// and summing it again each time. With over a thousand entries that ran constantly, including
/// on every mouse move.
public struct RecommendationGroup: Sendable, Identifiable {
    public let tier: Recommendation.Tier
    public let items: [Recommendation]
    public let totalSize: UInt64

    public var id: Int { tier.rawValue }

    public init(tier: Recommendation.Tier, items: [Recommendation]) {
        self.tier = tier
        self.items = items
        self.totalSize = items.reduce(UInt64(0)) { $0 &+ $1.size }
    }

    public static func group(_ recommendations: [Recommendation]) -> [RecommendationGroup] {
        var buckets: [Recommendation.Tier: [Recommendation]] = [:]
        for item in recommendations {
            buckets[item.tier, default: []].append(item)
        }
        return buckets.keys.sorted().map { RecommendationGroup(tier: $0, items: buckets[$0] ?? []) }
    }
}

public enum RecommendationEngine {

    /// Build artefacts and caches that any competent toolchain will recreate.
    /// Matched on exact directory name, and never descended into — the interesting unit is
    /// "this node_modules is 400 MB", not the twelve thousand files inside it.
    private static let regenerableDirectories: Set<String> = [
        "node_modules", "DerivedData", ".build", "__pycache__", ".venv", "venv",
        ".gradle", ".next", ".nuxt", "Pods", ".tox", ".pytest_cache", ".mypy_cache",
        "target",  // Rust and Maven
    ]

    private static let largeFileThreshold: UInt64 = 1_000_000_000  // 1 GB
    private static let staleInterval: TimeInterval = 180 * 24 * 3600  // ~6 months
    private static let downloadStaleInterval: TimeInterval = 90 * 24 * 3600

    public static func analyze(
        result: ScanResult,
        now: Date = Date()
    ) -> [Recommendation] {
        var found: [Recommendation] = []
        let rootPath = result.rootPath

        func walk(_ node: FileNode, components: [String]) {
            let path = ([rootPath] + components).joined(separator: "/")
                .replacingOccurrences(of: "//", with: "/")

            if node.isDirectory {
                if let match = classifyDirectory(node, components: components, path: path, now: now) {
                    found.append(match)
                    // Do not descend: the directory is the actionable unit, and its contents
                    // would otherwise generate hundreds of redundant suggestions.
                    return
                }
                for child in node.children {
                    walk(child, components: components + [child.name])
                }
            } else if let match = classifyFile(node, path: path, components: components, now: now) {
                found.append(match)
            }
        }

        for child in result.root.children {
            walk(child, components: [child.name])
        }

        // Largest first within each tier, so the most valuable action is always on top.
        return found.sorted {
            $0.tier == $1.tier ? $0.size > $1.size : $0.tier < $1.tier
        }
    }

    private static func classifyDirectory(
        _ node: FileNode, components: [String], path: String, now: Date
    ) -> Recommendation? {
        guard node.size > 0 else { return nil }

        if components.last == ".Trash" {
            return Recommendation(
                title: "Empty the Trash",
                detail: "\(node.fileCount.formatted()) items already marked for deletion.",
                path: path, size: node.size, tier: .safe, symbolName: "trash.fill")
        }

        if let name = components.last, regenerableDirectories.contains(name) {
            let project = components.dropLast().last ?? "this project"
            return Recommendation(
                title: "\(name) in \(project)",
                detail: "Build artefacts — your toolchain will regenerate these on next build.",
                path: path, size: node.size, tier: .safe, symbolName: "hammer.fill")
        }

        // Xcode's caches are the single largest reclaimable directory on most dev machines.
        if components.suffix(2) == ["Developer", "Xcode"] || components.last == "Archives" {
            return Recommendation(
                title: "Xcode \(components.last ?? "data")",
                detail: "Derived data and archives are rebuilt on demand.",
                path: path, size: node.size, tier: .safe, symbolName: "wrench.and.screwdriver.fill")
        }

        return nil
    }

    private static func classifyFile(
        _ node: FileNode, path: String, components: [String], now: Date
    ) -> Recommendation? {
        guard node.size >= largeFileThreshold else { return nil }

        let isDownload = components.contains("Downloads")
        let age = node.accessTime.map { now.timeIntervalSince($0) }
        let threshold = isDownload ? downloadStaleInterval : staleInterval

        // Access time is unreliable — volumes mounted `noatime` never update it, and some
        // backup tools touch every file. So an unknown or recent date is never treated as
        // evidence for deletion; only a confidently old one produces a suggestion.
        guard let age, age > threshold else { return nil }

        let months = Int(age / (30 * 24 * 3600))
        return Recommendation(
            title: node.name,
            detail: isDownload
                ? "Downloaded file, not opened in about \(months) months."
                : "Large file, not opened in about \(months) months.",
            path: path, size: node.size, tier: .review,
            symbolName: isDownload ? "arrow.down.circle.fill" : "doc.fill")
    }
}
