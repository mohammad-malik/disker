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

        /// The only way onto `found`.
        ///
        /// Every rule routes through here, so the protections hold for rules nobody has
        /// written yet. Before this existed the file branch appended straight to the array
        /// and consulted no policy at all: a large stale file inside a directory that merely
        /// *contains* protected content was offered, and files under an excluded directory
        /// were spared only because traversal happened to stop above them. Protection by
        /// accident is not protection.
        func emit(_ recommendation: Recommendation) {
            let path = recommendation.path
            guard !policy.isExcluded(path), !policy.containsProtectedContent(path) else { return }
            found.append(recommendation)
        }

        func walk(_ node: FileNode, components: [String]) {
            let path = ([rootPath] + components).joined(separator: "/")
                .replacingOccurrences(of: "//", with: "/")

            if node.isDirectory {
                // Stop at bundle boundaries. Everything below belongs to an installed
                // application, not to the user's projects, and removing any of it breaks
                // the app rather than reclaiming build output.
                //
                // `bundleRules` is the single exception, and it is the only code in the app
                // that ever sees inside a bundle. The `return` below it is load-bearing: the
                // walk never recurses past this point, so `classifyDirectory`, the sibling
                // hook, the stale-file rule and every rule written after this one remain
                // structurally unable to reach a bundle's interior. Adding a rule cannot open
                // that door by accident — it has to be typed into the switch inside
                // `bundleRules`, which a test pins.
                if isBundle(node.name) {
                    bundleRules(node, path: path).forEach(emit)
                    return
                }

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

                // Rules that read a whole set of siblings and keep some of them. Runs before
                // the single-node rules because it decides which children are still worth
                // visiting: `claimed` names the ones it has spoken for, and the walk skips
                // exactly those rather than stopping, since Arc's snapshots sit in a directory
                // full of things the walker still has to see.
                let siblings = classifySiblingSets(
                    in: node, components: components, path: path, now: now)
                if !siblings.matches.isEmpty {
                    siblings.matches.forEach(emit)
                }
                if !siblings.claimed.isEmpty {
                    for child in node.children where !siblings.claimed.contains(child.name) {
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
                    emit(match)
                    // Do not descend: the directory is the actionable unit, and its contents
                    // would otherwise generate hundreds of redundant suggestions.
                    return
                }
                for child in node.children {
                    walk(child, components: components + [child.name])
                }
            } else if let match = classifyFile(node, path: path, components: components, now: now) {
                emit(match)
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

    /// The only rules permitted inside a bundle.
    ///
    /// Two editing applications keep enormous regenerable caches inside their document
    /// packages, and refusing to look makes Disker useless to the users with the worst disk
    /// problems: a Final Cut library's render files run to hundreds of gigabytes. The risk is
    /// equally plain, because one directory over sits `Original Media`, which for a library
    /// imported with copy is frequently the only copy of the footage that exists.
    ///
    /// So this matches exact names at a fixed depth and never recurses. There is no name list
    /// shared with the generic rules, no fall-through, and no traversal: the only way for
    /// anything else inside a bundle to be suggested is for somebody to type its name here.
    ///
    /// Both are `review` rather than `safe`. Regenerating them costs no data, which reads like
    /// the definition of safe, but re-rendering a large library takes hours or days, and the
    /// engine already demotes regenerable-but-disruptive elsewhere for exactly that reason.
    /// Trashing files inside a library the app currently has open can also corrupt it, which
    /// the detail says out loud since Disker cannot tell whether the app is running.
    static func bundleRules(_ node: FileNode, path: String) -> [Recommendation] {
        switch (node.name as NSString).pathExtension {
        case "fcpbundle":
            // Depth 2: each child of the library is an event, and the caches sit inside it.
            return node.children.flatMap { event in
                event.children.filter {
                    $0.name == "Render Files" || $0.name == "Analysis Files"
                }
                .filter { $0.size > 0 }
                .map { generated in
                    Recommendation(
                        title: "\(generated.name) in \(event.name)",
                        detail: "Final Cut re-creates these on demand. Quit Final Cut first: "
                            + "changing a library it has open can corrupt it.",
                        path: path + "/" + event.name + "/" + generated.name,
                        size: generated.size, tier: .review, symbolName: "film.stack",
                        family: Recommendation.Family(
                            key: "fcp-generated-media", plural: "Final Cut render files",
                            scope: "events"))
                }
            }
        case "logicx":
            // Depth 1. Audio Files, Bounces and Project File Backups are siblings of this and
            // none of them regenerate: recordings, finished mixes, and the recovery chain.
            return node.children.filter { $0.name == "Freeze Files" && $0.size > 0 }
                .map { freeze in
                    Recommendation(
                        title: "Freeze files in \(node.name)",
                        detail: "Rendered frozen tracks. Logic rebuilds them only if the "
                            + "plugins that made them are still installed.",
                        path: path + "/" + freeze.name, size: freeze.size, tier: .review,
                        symbolName: "snowflake",
                        family: Recommendation.Family(
                            key: "logic-freeze-files", plural: "Logic freeze files",
                            scope: "projects"))
                }
        default:
            return []
        }
    }

    /// Rules that compare a directory's children against each other.
    ///
    /// `classifyDirectory` sees one node and answers yes or no about it. These rules cannot:
    /// deciding that a browser extension's `13.38.2.0_0` is dead requires seeing that
    /// `13.41.0.0_0` sits beside it. The hook returns the suggestions it wants plus the names
    /// it has spoken for, and only ever suggests the members that are stale — never the whole
    /// set with a note about what survives. If the rule emits four of six snapshots, then four
    /// is what every count in the app means, which is the honest number.
    ///
    /// `VersionOrder.superseded` carries two invariants for the version-shaped rules: a set of
    /// one yields nothing, so the only copy of something is never proposed, and one sibling
    /// that fails to parse silences the whole set.
    static func classifySiblingSets(
        in node: FileNode, components: [String], path: String, now: Date
    ) -> (matches: [Recommendation], claimed: Set<String>) {
        if let match = chromiumExtensionVersions(in: node, components: components, path: path) {
            return match
        }
        if let match = gradleVersionCaches(in: node, components: components, path: path) {
            return match
        }
        if let match = androidBuildToolVersions(in: node, components: components, path: path) {
            return match
        }
        if let match = appVersionDirectories(in: node, components: components, path: path) {
            return match
        }
        if let match = arcSidebarSnapshots(in: node, components: components, path: path) {
            return match
        }
        if let match = unityProject(in: node, path: path) { return match }
        if let match = unrealProject(in: node, path: path) { return match }
        return ([], [])
    }

    /// Chromium unpacks each extension into a version-named directory and is supposed to
    /// remove the old one on update. It frequently does not, especially after a force-quit,
    /// and only the highest version is ever loaded.
    ///
    /// Fires at the extension-id directory, and the anchor is the whole Chromium profile
    /// shape: `<browser>/User Data/<Profile>/Extensions/<id>`. A parent named `Extensions` on
    /// its own is not enough — `~/project/Extensions/widget/{1.0,2.0}` is somebody's own
    /// versioned folder, and this rule would have offered `1.0` as safe to delete.
    private static func chromiumExtensionVersions(
        in node: FileNode, components: [String], path: String
    ) -> (matches: [Recommendation], claimed: Set<String>)? {
        // …/User Data/<Profile>/Extensions/<extension id>
        guard components.count >= 4,
            components.suffix(4).first == "User Data",
            components.dropLast().last == "Extensions",
            let stale = VersionOrder.superseded(among: node.children.map(\.name))
        else { return nil }

        let staleNames = Set(stale)
        let matches = node.children.filter { staleNames.contains($0.name) && $0.size > 0 }
            .map { child in
                Recommendation(
                    title: "\(node.name) \(child.name)",
                    detail: "An older copy of a browser extension. Only the newest version is "
                        + "ever loaded, and that one stays.",
                    path: path + "/" + child.name, size: child.size, tier: .safe,
                    symbolName: "puzzlepiece.extension.fill",
                    family: Recommendation.Family(
                        key: "chromium-extension-versions",
                        plural: "old browser extension versions", scope: "places"))
            }
        return matches.isEmpty ? nil : (matches, Set(node.children.map(\.name)))
    }

    /// Gradle keeps a separate cache tree per Gradle version, so upgrading one project's
    /// wrapper leaves the previous version's multi-gigabyte directory untouched forever.
    ///
    /// Ordered by access time rather than by version number: the newest Gradle is not
    /// necessarily the one still in use, and a build that ran yesterday against 8.13 is what
    /// matters. An unknown access time keeps the directory, following the same rule the stale
    /// file logic uses — `nil` means unknown, never old.
    private static func gradleVersionCaches(
        in node: FileNode, components: [String], path: String
    ) -> (matches: [Recommendation], claimed: Set<String>)? {
        guard node.name == "caches", components.suffix(2).first == ".gradle" else { return nil }

        let versions = node.children.filter { VersionOrder.parse($0.name) != nil }
        guard versions.count >= 2 else { return nil }

        // Whichever version was used most recently is the live one.
        guard let newest = versions.compactMap(\.accessTime).max() else { return nil }
        let stale = versions.filter { child in
            guard let accessed = child.accessTime else { return false }
            return accessed < newest
        }
        guard !stale.isEmpty else { return nil }

        let matches = stale.map { child in
            Recommendation(
                title: "Gradle \(child.name)",
                detail: "A cache for a Gradle version you have stopped building with. The next "
                    + "build that needs it re-downloads its dependencies.",
                path: path + "/" + child.name, size: child.size, tier: .safe,
                symbolName: "shippingbox.fill",
                family: Recommendation.Family(
                    key: "gradle-version-caches", plural: "Gradle version caches",
                    scope: "versions"))
        }
        return (matches, Set(versions.map(\.name)))
    }

    /// One directory per Android build-tools release or platform API level, added on every SDK
    /// update and never pruned.
    ///
    /// The two shapes are named differently: build-tools directories are bare versions like
    /// `36.0.0`, while platforms are `android-36`. The prefix is stripped before comparing,
    /// and a name that does not fit its directory's shape silences the whole set — which is
    /// what happens to a preview platform such as `android-TiramisuPrivacySandbox`, since
    /// there is no sane place to order it against a number.
    ///
    /// Review rather than safe: a project's `build.gradle` can pin an exact version, and
    /// nothing in a directory name says which versions are pinned.
    private static func androidBuildToolVersions(
        in node: FileNode, components: [String], path: String
    ) -> (matches: [Recommendation], claimed: Set<String>)? {
        let isPlatforms = node.name == "platforms"
        guard node.name == "build-tools" || isPlatforms,
            components.dropLast().last == "sdk" || components.dropLast().last == "Sdk"
        else { return nil }

        // `android-36` orders as 36; anything else in a platforms directory does not order at
        // all, and `superseded` turns one unparseable entry into silence for the set.
        let prefix = "android-"
        let versions: [String: String] = node.children.reduce(into: [:]) { table, child in
            let version =
                isPlatforms
                ? (child.name.hasPrefix(prefix) ? String(child.name.dropFirst(prefix.count)) : child.name)
                : child.name
            table[child.name] = version
        }

        guard let stale = VersionOrder.superseded(among: Array(versions.values)) else {
            return nil
        }
        let staleVersions = Set(stale)
        let matches = node.children.filter { child in
            guard let version = versions[child.name] else { return false }
            return staleVersions.contains(version) && child.size > 0
        }
        .map { child in
            Recommendation(
                title: "Android \(node.name) \(child.name)",
                detail: "An older Android SDK component. The SDK manager re-downloads it "
                    + "if a project pins that version.",
                path: path + "/" + child.name, size: child.size, tier: .review,
                symbolName: "hammer.fill",
                family: Recommendation.Family(
                    key: "android-sdk-versions", plural: "old Android SDK versions",
                    scope: "versions"))
        }
        return matches.isEmpty ? nil : (matches, Set(node.children.map(\.name)))
    }

    /// Self-updating apps that unpack each build into a version-named directory beside the
    /// previous one, launch the newest, and never remove the old.
    ///
    /// Named apps only. The first version of this matched *any* directory under Application
    /// Support whose children were all version-shaped, which is a shape rather than a layout:
    /// versioned backups, per-release document stores and database directories look identical
    /// from the outside, and nothing about the shape proves the app ignores the older ones.
    /// Being right about Discord is not evidence about the next app that happens to store
    /// `1.0` and `2.0` side by side.
    ///
    /// The bar for adding a name here is knowing that the app launches the newest build and
    /// keeps the rest as dead weight.
    private static let selfUpdatingAppDirectories: Set<String> = [
        "discord", "discordcanary", "discordptb", "discorddevelopment",
    ]

    private static func appVersionDirectories(
        in node: FileNode, components: [String], path: String
    ) -> (matches: [Recommendation], claimed: Set<String>)? {
        guard components.dropLast().last == "Application Support",
            selfUpdatingAppDirectories.contains(node.name.lowercased()),
            node.children.count >= 2,
            let stale = VersionOrder.superseded(among: node.children.map(\.name))
        else { return nil }

        let staleNames = Set(stale)
        let matches = node.children.filter { staleNames.contains($0.name) && $0.size > 0 }
            .map { child in
                Recommendation(
                    title: "\(node.name) \(child.name)",
                    detail: "An older build of \(node.name). The app launches the newest one, "
                        + "which stays where it is.",
                    path: path + "/" + child.name, size: child.size, tier: .safe,
                    symbolName: "app.badge.fill",
                    family: Recommendation.Family(
                        key: "stale-app-versions", plural: "old app versions", scope: "apps"))
            }
        return matches.isEmpty ? nil : (matches, Set(node.children.map(\.name)))
    }

    /// Arc snapshots its whole tab and space layout to a timestamped file on every significant
    /// change and never prunes them. The live file is the one *without* a timestamp, which is
    /// why this matches on the timestamp rather than on a `StorableSidebar*` glob.
    ///
    /// Keeps the newest few as a hedge: these are the only record of a space deleted months
    /// ago, and recovering one means hand-editing JSON, so the cost of keeping three is a few
    /// megabytes and the cost of keeping none is occasionally total.
    private static func arcSidebarSnapshots(
        in node: FileNode, components: [String], path: String
    ) -> (matches: [Recommendation], claimed: Set<String>)? {
        guard node.name == "Arc", components.dropLast().last == "Application Support"
        else { return nil }

        let snapshots = node.children.filter {
            $0.name.hasPrefix("StorableSidebar.") && $0.name.hasSuffix(".json")
                && $0.name != "StorableSidebar.json"
        }
        // Timestamped names sort chronologically as text, which is what the format is for.
        let stale = snapshots.sorted { $0.name > $1.name }.dropFirst(3)
        guard stale.count >= 2 else { return nil }

        let matches = stale.map { child in
            Recommendation(
                title: child.name,
                detail: "A snapshot of your Arc sidebar. Arc writes a new one on every change "
                    + "and reads none of them; the live sidebar and the three newest stay.",
                path: path + "/" + child.name, size: child.size, tier: .safe,
                symbolName: "clock.arrow.circlepath",
                family: Recommendation.Family(
                    key: "arc-sidebar-snapshots", plural: "old Arc sidebar snapshots",
                    scope: "files", phrasing: .counted))
        }
        // Only the snapshots are spoken for; the rest of Arc's directory is still walked.
        return (matches, Set(snapshots.map(\.name)))
    }

    /// Unity rebuilds `Library` entirely from `Assets` and `ProjectSettings`, so it is pure
    /// derived data — and `Library` is also the name of the single most important directory in
    /// a macOS home folder.
    ///
    /// The sibling test is what separates those two, and it is not optional: `Assets` *and*
    /// `ProjectSettings` must both sit beside it. That signature belongs to Unity and to
    /// nothing else, and `~/Library` has neither. Handled here rather than in
    /// `classifyDirectory` because the evidence lives in the parent's other children.
    private static func unityProject(
        in node: FileNode, path: String
    ) -> (matches: [Recommendation], claimed: Set<String>)? {
        let names = Set(node.children.map(\.name))
        guard names.contains("Assets"), names.contains("ProjectSettings"),
            let library = node.children.first(where: { $0.name == "Library" && $0.isDirectory }),
            library.size > 0
        else { return nil }

        let match = Recommendation(
            title: "Unity Library in \(node.name)",
            detail: "Unity re-imports this from Assets when the project opens. Close the "
                + "project first.",
            path: path + "/Library", size: library.size, tier: .safe,
            symbolName: "cube.transparent.fill",
            family: Recommendation.Family(
                key: "unity-library", plural: "Unity import caches", scope: "projects"))
        // Claimed so the walk does not go inside and start suggesting its contents piecemeal.
        return ([match], ["Library"])
    }

    /// Unreal's derived data and build intermediates rebuild from the project, and both names
    /// are ordinary enough English that a bare name match would be wrong.
    ///
    /// Gated on a `.uproject` file sitting beside them. `Saved` is deliberately absent: most
    /// cleanup guides on the internet lump it in with these two, but it holds autosaves and
    /// crash recovery, which for someone whose editor died before they saved is the only copy
    /// of their work.
    private static func unrealProject(
        in node: FileNode, path: String
    ) -> (matches: [Recommendation], claimed: Set<String>)? {
        guard node.children.contains(where: {
            !$0.isDirectory && ($0.name as NSString).pathExtension == "uproject"
        }) else { return nil }

        let derived = node.children.filter {
            $0.isDirectory && ($0.name == "DerivedDataCache" || $0.name == "Intermediate")
                && $0.size > 0
        }
        guard !derived.isEmpty else { return nil }

        let matches = derived.map { child in
            Recommendation(
                title: "\(child.name) in \(node.name)",
                detail: "Compiled shaders and build intermediates Unreal re-derives when the "
                    + "project opens. The first open afterwards is slow.",
                path: path + "/" + child.name, size: child.size, tier: .safe,
                symbolName: "cube.fill",
                family: Recommendation.Family(
                    key: "unreal-derived-data", plural: "Unreal derived data caches",
                    scope: "projects"))
        }
        return (matches, Set(derived.map(\.name)))
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

        if let match = mediaToolCaches(node, components: components, path: path) {
            return match
        }

        if let match = browserProfileCaches(node, components: components, path: path) {
            return match
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

    /// Caches belonging to the editing and design tools, which are the largest regenerable
    /// directories on a working creative machine.
    ///
    /// Every match here earns its place from an anchored path or a vendor-specific name. None
    /// of them match a bare English word: "Renders", "Previews", "Proxies" and "Cache" are
    /// where a large share of 3D artists and photographers keep finished work, and matching one
    /// of those on name alone is the fastest way to delete someone's output.
    private static func mediaToolCaches(
        _ node: FileNode, components: [String], path: String
    ) -> Recommendation? {
        guard let name = components.last, node.size > 0 else { return nil }

        func made(
            _ title: String, _ detail: String, _ tier: Recommendation.Tier, _ symbol: String,
            key: String, plural: String, scope: String
        ) -> Recommendation {
            Recommendation(
                title: title, detail: detail, path: path, size: node.size, tier: tier,
                symbolName: symbol,
                family: Recommendation.Family(key: key, plural: plural, scope: scope))
        }

        // Every Adobe video and audio app shares one media cache, keyed on the source clip
        // rather than the project, so it long outlives the projects that filled it. Anchored
        // under the user's own Application Support: the copy at the system root is licensing
        // data, not cache.
        if components.first == "Users", components.count >= 5,
            Array(components.suffix(5).prefix(4))
                == ["Library", "Application Support", "Adobe", "Common"],
            name == "Media Cache Files" || name == "Media Cache"
        {
            return made(
                "Adobe media cache",
                "Decoded audio and video that Premiere and After Effects rebuild on import.",
                .safe, "film.stack",
                key: "adobe-media-cache", plural: "Adobe media caches", scope: "places")
        }

        // Photoshop and Lightroom both ship a Purge button for this one.
        if components.suffix(3) == ["Library", "Caches", "Adobe Camera Raw"]
            || components.suffix(5) == ["Library", "Caches", "Adobe", "Camera Raw", "Cache"]
        {
            return made(
                "Camera Raw cache",
                "Decoded RAW previews Lightroom and Photoshop rebuild as you browse.",
                .safe, "camera.filters",
                key: "camera-raw-cache", plural: "Camera Raw caches", scope: "places")
        }

        // The default cap is a share of the drive, so this grows to fill whatever it is given.
        // The name is specific enough to match wherever the user pointed their scratch disk.
        if name.hasPrefix("Adobe After Effects Disk Cache"), name.hasSuffix(".noindex") {
            return made(
                "After Effects disk cache",
                "Cached preview frames After Effects re-renders as you scrub.",
                .safe, "square.stack.3d.down.right.fill",
                key: "ae-disk-cache", plural: "After Effects disk caches", scope: "places")
        }

        // One folder per directory that has ever held a project, so an editor who organises by
        // job has one per job. Exact names, never a prefix match on "Adobe Premiere Pro ":
        // "Adobe Premiere Pro Auto-Save" is the crash recovery copy of the project itself.
        if name == "Adobe Premiere Pro Preview Files"
            || name == "Adobe Premiere Pro Video Previews"
            || name == "Adobe Premiere Pro Audio Previews"
        {
            let project = components.dropLast().last ?? "this project"
            return made(
                "Preview files in \(project)",
                "Rendered timeline previews Premiere recreates when you render again.",
                .safe, "rectangle.stack.fill",
                key: "premiere-previews", plural: "Premiere preview files", scope: "projects")
        }

        // Order matters: "Smart Previews.lrdata" also ends in " Previews.lrdata", and smart
        // previews are what let a photographer edit with the originals offline. For anyone
        // travelling with a laptop they are the only editable copy on the machine.
        if name.hasSuffix(" Smart Previews.lrdata") {
            return made(
                "Smart previews for \(catalogName(from: name, suffix: " Smart Previews.lrdata"))",
                "Lossy copies that let you edit with the originals offline. Rebuilding them "
                    + "needs the originals back.",
                .review, "photo.stack",
                key: "lightroom-smart-previews", plural: "Lightroom smart previews",
                scope: "catalogs")
        }
        if name.hasSuffix(" Previews.lrdata") {
            return made(
                "Previews for \(catalogName(from: name, suffix: " Previews.lrdata"))",
                "Thumbnail and preview cache Lightroom rebuilds as you browse.",
                .safe, "photo.stack",
                key: "lightroom-previews", plural: "Lightroom preview caches", scope: "catalogs")
        }

        // Resolve's working folder is configurable, so these cannot be anchored to a path. The
        // names are CamelCase and vendor-specific, which is what makes matching them at any
        // depth defensible where "Cache" or "Proxies" would not be. `.gallery`, which holds a
        // colourist's graded stills and regenerates from nothing, is not in this list.
        if name == "CacheClip" || name == "OptimizedMedia" {
            return made(
                "Resolve render cache",
                "Cached renders Resolve rebuilds when you reopen the timeline.",
                .safe, "wand.and.rays",
                key: "resolve-cache", plural: "Resolve render caches", scope: "places")
        }
        if name == "ProxyMedia" {
            return made(
                "Resolve proxy media",
                "Proxies Resolve rebuilds from the original footage, if the originals are "
                    + "still online.",
                .review, "wand.and.rays",
                key: "resolve-proxy", plural: "Resolve proxy media", scope: "places")
        }

        return nil
    }

    /// Strips a known suffix so a row can name the catalog rather than the directory.
    private static func catalogName(from name: String, suffix: String) -> String {
        String(name.dropLast(suffix.count))
    }

    /// Chromium's compiled-JavaScript, GPU and shader caches, which live in each app's own
    /// profile rather than in `~/Library/Caches`.
    ///
    /// Every Electron app carries a full Chromium, so a modern Mac has dozens of these. Mole
    /// owns `~/Library/Caches` and does not reach here, which is why they are Disker's to
    /// claim.
    ///
    /// The dangerous part is what sits beside them. `Local Storage`, `IndexedDB`,
    /// `Local Extension Settings` and `Service Worker/Database` are all substantial and all
    /// hold real state, so a rule that reaches one directory too far logs the user out of
    /// everything. Hence exact names, and `Cache_Data` matched only inside `Cache` rather than
    /// `Cache` itself.
    private static func browserProfileCaches(
        _ node: FileNode, components: [String], path: String
    ) -> Recommendation? {
        guard let name = components.last, node.size > 0,
            components.contains("Application Support") || components.contains("Containers")
                || components.contains("Group Containers")
        else { return nil }

        let parent = components.dropLast().last
        let isCache =
            rebuildableChromiumCaches.contains(name)
            || (name == "Cache_Data" && parent == "Cache")
            || ((name == "CacheStorage" || name == "ScriptCache") && parent == "Service Worker")
        guard isCache else { return nil }

        let app = appName(inside: components) ?? "an app"
        return Recommendation(
            title: "\(name) in \(app)",
            detail: "Compiled scripts and shaders the app rebuilds on next launch, costing a "
                + "second or two once.",
            path: path, size: node.size, tier: .safe, symbolName: "bolt.horizontal.fill",
            family: Recommendation.Family(
                key: "chromium-profile-cache", plural: "rebuildable app caches", scope: "apps"))
    }

    /// Exact directory names Chromium uses for caches it will rebuild without being asked.
    private static let rebuildableChromiumCaches: Set<String> = [
        "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache",
        "ShaderCache", "CachedData", "component_crx_cache",
    ]

    /// The component just below the container directory, which is the app these caches belong
    /// to — good enough to name a row without reading anything.
    private static func appName(inside components: [String]) -> String? {
        for anchor in ["Application Support", "Containers", "Group Containers"] {
            if let index = components.lastIndex(of: anchor), index + 1 < components.count {
                return components[index + 1]
            }
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
            symbolName: isDownload ? "arrow.down.circle.fill" : "doc.fill",
            family: isDownload ? .staleDownloads : .staleFiles)
    }
}
