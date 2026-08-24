import Foundation

public struct Recommendation: Sendable, Identifiable {
    public let id = UUID()
    public let title: String
    public let detail: String
    public let path: String
    public let size: UInt64
    public let tier: Tier
    public let symbolName: String
    /// What acting on this suggestion actually does.
    public let action: Action
    /// What kind of thing this is, which is what lets several of them collapse into one row.
    public let family: Family

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
        tier: Tier, symbolName: String, family: Family, action: Action = .moveToTrash
    ) {
        self.family = family
        self.title = title
        self.detail = detail
        self.path = path
        self.size = size
        self.tier = tier
        self.symbolName = symbolName
        self.action = action

        let home = NSHomeDirectory()
        let parent = (path as NSString).deletingLastPathComponent
        self.displayPath =
            parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }

    /// Returns a copy at a different tier, used when a match is real but riskier than the
    /// rule that found it assumed.
    func reclassified(as tier: Tier, detail: String) -> Recommendation {
        Recommendation(
            title: title, detail: detail, path: path, size: size,
            tier: tier, symbolName: symbolName, family: family, action: action)
    }

    /// What a suggestion *is*, as opposed to where it was found.
    ///
    /// A real developer's disk turns up the same artefact over and over: fifteen
    /// `node_modules`, four virtual environments, three `.next` directories. Listed one per
    /// row they bury everything else, and no single row is worth acting on — the interesting
    /// figure is what all the `node_modules` come to together. Two suggestions share a family
    /// when they are the same kind of thing, whatever project or app they belong to.
    ///
    /// Deliberately not a fixed enum of dev tools. Grouping is a property of the list, not of
    /// software development: any rule that can name its output gets the same treatment, which
    /// is what keeps the mechanism useful for the caches a photographer or a video editor
    /// accumulates rather than only for build output.
    public struct Family: Hashable, Sendable {
        /// Identical keys are the same kind of thing. Two spellings of one idea share a key,
        /// so `.venv` and `venv` collapse together rather than making two groups of one.
        public let key: String
        /// What to call several of them at once, without a count: "Python virtual environments".
        public let plural: String
        /// What the count is a count *of*: "projects", "places".
        public let scope: String
        /// Whether the members are folders scattered around the disk or loose items.
        public let phrasing: Phrasing

        public init(key: String, plural: String, scope: String, phrasing: Phrasing = .scattered) {
            self.key = key
            self.plural = plural
            self.scope = scope
            self.phrasing = phrasing
        }

        /// A family of folders reads by where they are; a family of files reads by how many
        /// there are. "Large files you have not opened across 3 files" was the sentence that
        /// made the distinction necessary.
        public enum Phrasing: Sendable, Hashable {
            /// "node_modules across 14 projects"
            case scattered
            /// "3 large files you have not opened"
            case counted
        }

        /// How the group's row reads once there are several of them.
        public func groupTitle(count: Int) -> String {
            switch phrasing {
            case .scattered: return "\(plural) across \(count) \(scope)"
            case .counted: return "\(count) \(plural)"
            }
        }

        public static let trash = Family(key: "trash", plural: "Trash", scope: "accounts")
        public static let staleDownloads = Family(
            key: "stale-downloads", plural: "downloads you have not opened in months",
            scope: "files", phrasing: .counted)
        public static let staleFiles = Family(
            key: "stale-files", plural: "large files you have not opened in months",
            scope: "files", phrasing: .counted)

        /// The family for a directory of regenerable output, named after the directory itself
        /// so the row says the word the user would recognise.
        public static func directory(named name: String) -> Family {
            if let known = knownDirectories[name] { return known }
            return Family(key: name, plural: name, scope: "places")
        }

        private static let knownDirectories: [String: Family] = {
            let venv = Family(
                key: "virtualenv", plural: "Python virtual environments", scope: "projects")
            let entries: [(String, Family)] = [
                ("node_modules", Family(key: "node_modules", plural: "node_modules", scope: "projects")),
                (".venv", venv),
                ("venv", venv),
                (".next", Family(key: ".next", plural: "Next.js build output", scope: "projects")),
                (".nuxt", Family(key: ".nuxt", plural: "Nuxt build output", scope: "projects")),
                (".build", Family(key: ".build", plural: "Swift build folders", scope: "projects")),
                ("target", Family(key: "target", plural: "Rust and Maven build folders", scope: "projects")),
                ("Pods", Family(key: "Pods", plural: "CocoaPods folders", scope: "projects")),
                ("DerivedData", Family(key: "DerivedData", plural: "DerivedData folders", scope: "places")),
                // "places", not "projects": a virtual environment alone can hold hundreds of
                // __pycache__ directories, and calling those projects would be a lie about
                // where the space went.
                ("__pycache__", Family(key: "__pycache__", plural: "Python bytecode caches", scope: "places")),
                (".pytest_cache", Family(key: ".pytest_cache", plural: "pytest caches", scope: "places")),
                (".mypy_cache", Family(key: ".mypy_cache", plural: "mypy caches", scope: "places")),
                (".tox", Family(key: ".tox", plural: "tox environments", scope: "places")),
                (".gradle", Family(key: ".gradle", plural: "Gradle caches", scope: "places")),
            ]
            return Dictionary(uniqueKeysWithValues: entries)
        }()
    }

    /// How a suggestion is carried out.
    ///
    /// Not every suggestion is a move to the Trash, and one of them cannot be: the Trash
    /// itself. `FileManager.trashItem` refuses to put the Trash inside the Trash, so the
    /// "Empty the Trash" row failed with "Trash couldn't be moved to the trash" every time
    /// it was clicked. Emptying is a different operation on a different
    /// target — the *contents* of that folder, deleted outright — so it is modelled as one
    /// rather than bolted onto the deletion path.
    public enum Action: Sendable {
        /// Reversible: the item goes to the Trash and ⌘Z brings it back.
        case moveToTrash
        /// Irreversible: everything inside the folder is deleted for good. Confirmed
        /// separately, and never registered with the UndoManager, because nothing can put
        /// it back.
        case emptyTrash
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
    /// What the list actually draws: single suggestions and collapsed families, largest first.
    public let entries: [RecommendationEntry]
    public let totalSize: UInt64

    public var id: Int { tier.rawValue }

    public init(tier: Recommendation.Tier, items: [Recommendation]) {
        self.tier = tier
        self.items = items
        self.totalSize = items.reduce(UInt64(0)) { $0 &+ $1.size }
        self.entries = Self.entries(for: items, tier: tier)
    }

    /// How many of one kind it takes before they collapse into a single row.
    ///
    /// Three, not two. A group costs a click to open, so replacing two rows with one row that
    /// hides two is not a saving; by three it is, and by fifteen it is the difference between
    /// a list you can read and the one this replaced.
    public static let clusterThreshold = 3

    private static func entries(
        for items: [Recommendation], tier: Recommendation.Tier
    ) -> [RecommendationEntry] {
        var byFamily: [Recommendation.Family: [Recommendation]] = [:]
        var order: [Recommendation.Family] = []
        for item in items {
            if byFamily[item.family] == nil { order.append(item.family) }
            byFamily[item.family, default: []].append(item)
        }

        var entries: [RecommendationEntry] = []
        for family in order {
            let members = byFamily[family] ?? []
            // Only reversible suggestions collapse. Acting on a group acts on every member at
            // once, and offering that for the one action with no undo behind it would be a
            // bulk permanent delete a single click away.
            let clusterable = members.allSatisfy { $0.action == .moveToTrash }
            guard members.count >= clusterThreshold, clusterable else {
                entries.append(contentsOf: members.map { .single($0) })
                continue
            }
            entries.append(
                .cluster(
                    RecommendationCluster(
                        tier: tier, family: family,
                        items: members.sorted { $0.size > $1.size })))
        }
        return entries.sorted { $0.size > $1.size }
    }

    public static func group(_ recommendations: [Recommendation]) -> [RecommendationGroup] {
        var buckets: [Recommendation.Tier: [Recommendation]] = [:]
        for item in recommendations {
            buckets[item.tier, default: []].append(item)
        }
        return buckets.keys.sorted().map { RecommendationGroup(tier: $0, items: buckets[$0] ?? []) }
    }
}

/// One row of the recommendations list: either a suggestion on its own, or a family of them
/// collapsed behind a single row that can be expanded.
public enum RecommendationEntry: Sendable, Identifiable {
    case single(Recommendation)
    case cluster(RecommendationCluster)

    public var id: String {
        switch self {
        case .single(let item): return item.id.uuidString
        case .cluster(let cluster): return cluster.id
        }
    }

    /// What the row is sorted by, so a family of fifteen small folders can outrank a single
    /// large one when their total says it should.
    public var size: UInt64 {
        switch self {
        case .single(let item): return item.size
        case .cluster(let cluster): return cluster.totalSize
        }
    }
}

/// Several suggestions of one kind, shown as one row.
public struct RecommendationCluster: Sendable, Identifiable {
    public let tier: Recommendation.Tier
    public let family: Recommendation.Family
    /// Largest first, which is also the order the expanded rows appear in.
    public let items: [Recommendation]
    public let totalSize: UInt64

    /// Stable across rebuilds of the list, so an expanded group stays expanded when the tree
    /// changes underneath it. Deliberately not the members' ids, which are fresh UUIDs on
    /// every analysis pass.
    public var id: String { "\(tier.rawValue):\(family.key)" }

    public var title: String { family.groupTitle(count: items.count) }
    /// Every member of a family carries the same rationale, so the first one speaks for all.
    public var detail: String { items.first?.detail ?? "" }
    public var symbolName: String { items.first?.symbolName ?? "folder.fill" }

    /// The largest member, named. It is the one worth looking at first, and it tells the user
    /// what sort of place these were found in without expanding the group.
    public var largest: Recommendation? { items.first }

    /// What to call the largest member on the group's second line.
    ///
    /// For folders that is the project containing it, not the suggestion's own title: those
    /// titles already read "node_modules in meta-automation", so using one here produced
    /// "largest 552.1 MB in node_modules in meta-automation". For loose files it is the file.
    public var largestLabel: String? {
        guard let largest else { return nil }
        switch family.phrasing {
        case .scattered: return (largest.displayPath as NSString).lastPathComponent
        case .counted: return largest.title
        }
    }

    public init(
        tier: Recommendation.Tier, family: Recommendation.Family, items: [Recommendation]
    ) {
        self.tier = tier
        self.family = family
        self.items = items
        self.totalSize = items.reduce(UInt64(0)) { $0 &+ $1.size }
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

    /// Directory suffixes that mark a macOS bundle.
    ///
    /// Recommendations never descend into these. Electron and similar frameworks ship a real
    /// `node_modules` inside `Contents/Resources`, and it matched the build-artifact rule
    /// exactly — so the list offered to delete the internals of installed applications, which
    /// would break them. Nothing inside a bundle is a build artifact from the user's point of
    /// view; it is part of the shipped program.
    private static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "appex", "xpc", "plugin", "kext",
        "prefPane", "qlgenerator", "component", "systemextension", "dext",
        "mdimporter", "saver", "service", "wdgt", "photoslibrary", "musiclibrary",
        "tvlibrary", "fcpbundle", "logicx", "band", "sparsebundle",
    ]

    static func isBundle(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && bundleExtensions.contains(ext)
    }

    private static let largeFileThreshold: UInt64 = 1_000_000_000  // 1 GB
    private static let staleInterval: TimeInterval = 180 * 24 * 3600  // ~6 months
    private static let downloadStaleInterval: TimeInterval = 90 * 24 * 3600

    public static func analyze(
        result: ScanResult,
        now: Date = Date(),
        policy: SafetyPolicy = SafetyPolicy.loadingMoleWhitelist()
    ) -> [Recommendation] {
        var found: [Recommendation] = []
        let rootPath = result.rootPath

        func walk(_ node: FileNode, components: [String]) {
            let path = ([rootPath] + components).joined(separator: "/")
                .replacingOccurrences(of: "//", with: "/")

            if node.isDirectory {
                // Stop at bundle boundaries. Everything below belongs to an installed
                // application, not to the user's projects, and removing any of it breaks
                // the app rather than reclaiming build output.
                if isBundle(node.name) { return }

                // Installed software and anything the user told Mole to protect. Descending
                // is pointless too — nothing beneath a global install root is build output.
                if policy.isExcluded(path) { return }

                // Holds something protected, so it cannot be offered as a whole — but keep
                // walking, since unprotected artifacts may still sit inside it.
                if policy.containsProtectedContent(path) {
                    for child in node.children {
                        walk(child, components: components + [child.name])
                    }
                    return
                }

                if var match = classifyDirectory(node, components: components, path: path, now: now) {
                    // Regenerable, but removing it breaks a working tool until it can
                    // re-download. That is not what "safe" should promise.
                    if policy.isToolRuntime(path), match.tier == .safe {
                        match = match.reclassified(
                            as: .review,
                            detail: "Cache for an installed tool — it will re-download this, "
                                + "but the tool stops working until it does.")
                    }
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

        if isUserTrash(components: components) {
            return Recommendation(
                title: "Empty the Trash",
                detail: "\(node.fileCount.formatted()) items already marked for deletion. "
                    + "Emptying is permanent.",
                path: path, size: node.size, tier: .safe, symbolName: "trash.fill",
                family: .trash, action: .emptyTrash)
        }

        if let name = components.last, regenerableDirectories.contains(name) {
            let project = components.dropLast().last ?? "this project"
            return Recommendation(
                title: "\(name) in \(project)",
                detail: "Build artefacts — your toolchain will regenerate these on next build.",
                path: path, size: node.size, tier: .safe, symbolName: "hammer.fill",
                family: .directory(named: name))
        }

        // Xcode's caches are the single largest reclaimable directory on most dev machines.
        //
        // Requires the full Library/Developer/Xcode location rather than matching a bare
        // "Archives" component: that looser rule matched /private/var/db/powerlog/Library/
        // BatteryLife/Archives, offering to delete system power logs as "Xcode Archives".
        if components.count >= 3,
            components.suffix(3).prefix(2) == ["Library", "Developer"],
            components.dropLast().last == "Xcode" || components.suffix(2).first == "Xcode"
        {
            return Recommendation(
                title: "Xcode \(components.last ?? "data")",
                detail: "Derived data and archives are rebuilt on demand.",
                path: path, size: node.size, tier: .safe,
                symbolName: "wrench.and.screwdriver.fill",
                family: .directory(named: components.last ?? "Xcode"))
        }

        return nil
    }

    /// Whether these components name a real per-account Trash.
    ///
    /// The position matters, not just the name. This rule used to match any directory called
    /// `.Trash` anywhere on the volume, and it hands out the one action in the app that
    /// deletes without a Trash to recover from — so a checked-in fixture directory, a synced
    /// folder, or a `.Trash` inside a disk image would have had its contents destroyed on the
    /// strength of its name alone. Only `Users/<account>/.Trash` is somewhere macOS actually
    /// puts deleted files.
    ///
    /// Anything else named `.Trash` simply falls through to the ordinary rules, which is the
    /// safe default: at worst it goes unsuggested.
    static func isUserTrash(components: [String]) -> Bool {
        guard components.count == 3, components.last == ".Trash" else { return false }
        // `home` is the automount path to the same place.
        return components.first == "Users" || components.first == "home"
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
            symbolName: isDownload ? "arrow.down.circle.fill" : "doc.fill",
            family: isDownload ? .staleDownloads : .staleFiles)
    }
}
