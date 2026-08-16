import AppKit
import DiskerCore
import Observation
import SwiftUI

/// Single source of truth for the window.
@MainActor
@Observable
final class AppModel {
    enum ScanState {
        case idle
        case scanning(ScanProgress?)
        case loaded(ScanResult)
        case failed(String)
    }

    enum Section: Hashable, Identifiable {
        case overview
        case recommendations
        case mole
        /// A top-level folder from the scan, opened as its own view.
        case location(String)

        var id: String {
            switch self {
            case .overview: return "overview"
            case .recommendations: return "recommendations"
            case .mole: return "mole"
            case .location(let name): return "location:\(name)"
            }
        }

        var title: String {
            switch self {
            case .overview: return "Storage Overview"
            case .recommendations: return "Recommendations"
            case .mole: return "Mole"
            case .location(let name): return name
            }
        }

        var symbolName: String {
            switch self {
            case .overview: return "chart.pie.fill"
            case .recommendations: return "sparkles"
            case .mole: return "wand.and.sparkles"
            case .location: return "folder.fill"
            }
        }

        static var fixed: [Section] { [.overview, .recommendations, .mole] }
    }

    var section: Section = .overview
    /// The inspector is collapsible; the chart is the point of the window and deserves the
    /// space on a laptop display.
    ///
    /// This is the user's *preference*, not whether the panel is on screen — sections with
    /// nothing to inspect suppress it without disturbing the preference. Read
    /// `sectionSupportsInspector` alongside it rather than clearing this.
    var showsInspector = true

    /// Whether the current section has anything for the inspector to describe.
    ///
    /// Lives here because the detail view, the toolbar, and the View menu all need the same
    /// answer. It was duplicated across two of them, and the third never got the check at
    /// all — which is how the menu ended up offering "Hide Details" in sections that have
    /// no details to hide.
    var sectionSupportsInspector: Bool {
        switch section {
        case .overview, .location: return true
        case .recommendations, .mole: return false
        }
    }

    let moleSession = MoleSession()
    var moleConfiguration = MoleConfiguration()

    /// Whether the Mole sheet is showing the terminal rather than the options form.
    ///
    /// Lives here rather than in the sheet's `@State` because runs can start from outside the
    /// sheet's own buttons — "Manage whitelist" launches one while the options form is on
    /// screen. As sheet-local state it never flipped, so the whitelist editor started
    /// invisibly behind the form and the button looked broken.
    var moleShowingTerminal = false
    var scanState: ScanState = .idle
    var volume: VolumeInfo?
    var moleReport: MoleReport?
    var isLoadingMole = false
    /// When the displayed Mole preview was taken, if it came from cache rather than a run
    /// just now. Shown alongside the figure so a day-old number is never mistaken for live.
    var moleCheckedAt: Date?

    /// Nodes from the scan root down to whatever the chart is currently centred on.
    /// Doubles as the breadcrumb and as the source of full paths, which is why nodes
    /// themselves carry no parent pointer.
    var drillPath: [FileNode] = []

    var hoveredSegment: SunburstSegment?
    var selectedSegment: SunburstSegment?

    /// Selects a wedge in response to a click, revealing the inspector if it is hidden.
    ///
    /// Selecting something is a request to see what it is, and the inspector is the only
    /// place that answer appears — leaving it collapsed makes the click look like it did
    /// nothing. Deliberately a method rather than a `didSet` on `selectedSegment`: that
    /// property is also cleared programmatically on rescan and on drilling, and none of
    /// those should reopen a panel the user closed.
    func selectFromClick(_ segment: SunburstSegment?) {
        selectedSegment = segment
        guard segment != nil, !showsInspector else { return }
        showsInspector = true
    }

    var recommendations: [Recommendation] = [] {
        didSet { recommendationGroups = RecommendationGroup.group(recommendations) }
    }
    /// Grouped once on assignment, so the view never re-derives it while scrolling.
    private(set) var recommendationGroups: [RecommendationGroup] = []
    /// Whether the grant is currently held. Starts optimistic so a launch showing a cached
    /// scan does not flash a warning before the real check has run.
    ///
    /// This has to be refreshed wherever a scan is *displayed*, not only where one is taken.
    /// Only `scan()` used to set it, so a cached scan was described using a grant state from
    /// whenever that scan happened to be taken — which could be days earlier, and was simply
    /// the `true` default on a fresh launch.
    var hasFullDiskAccess = true
    var showingAccessSheet = false
    /// Surfaced inline rather than as a modal alert — a failed delete is information,
    /// not a decision the user has to stop and make.
    var lastError: String?

    /// Drives Cmd+Z. Held here rather than on a view so undo survives selection changes.
    let undoManager = UndoManager()

    private let scanner = VolumeScanner()
    private let mole = MoleClient()

    /// Volumes offered in the disk picker.
    var availableVolumes: [Volume] = []
    /// The volume currently being analysed.
    var selectedVolume: Volume?

    /// The data volume, not `/`. The sealed system volume is ~12 GB of immutable OS that a
    /// user can neither browse nor reclaim, so rooting the chart there would show them
    /// almost nothing they care about.
    var scanRoot: String { selectedVolume?.path ?? "/System/Volumes/Data" }

    var showingMoleSheet = false
    /// Pending deletion awaiting confirmation, shown in a dialog before anything moves.
    var pendingDeletion: (path: String, name: String, size: UInt64, components: [String])?
    private var reconcileTask: Task<Void, Never>?
    private var reconcileQueued = false
    /// Bumped whenever the window starts describing something else, so a background pass
    /// still in flight for the old thing knows to throw its result away.
    private var treeGeneration = 0

    func refreshVolumes() {
        availableVolumes = VolumeCatalog.mountedVolumes()
        if selectedVolume == nil || !availableVolumes.contains(where: { $0.id == selectedVolume?.id })
        {
            selectedVolume = VolumeCatalog.defaultVolume() ?? availableVolumes.first
        }
    }

    /// Switches volumes, showing that disk's cached scan if there is one.
    func select(_ volume: Volume) async {
        guard volume.id != selectedVolume?.id else { return }
        treeGeneration += 1
        // The pass still draining belongs to the old disk, so its "updating…" note
        // does not describe this one.
        isReconciling = false
        selectedVolume = volume
        drillPath = []
        segments = []
        selectedSegment = nil
        hoveredSegment = nil
        recommendations = []
        refreshVolume()
        if await !loadCachedScan() {
            await scan()
        }
    }

    var currentRoot: FileNode? { drillPath.last }

    var breadcrumb: [FileNode] { drillPath }

    var segments: [SunburstSegment] = []

    /// Age of the displayed scan, when it came from cache rather than a fresh walk.
    var cachedAt: Date?

    func refreshVolume() {
        volume = VolumeInfo.current(for: scanRoot)
    }

    /// Shows the previous scan immediately if there is one.
    ///
    /// Returns whether anything was restored, so the caller can decide to scan instead of
    /// making the user watch a spinner for numbers that have barely changed since yesterday.
    @discardableResult
    func loadCachedScan() async -> Bool {
        guard let entry = ScanCache.shared.load(expecting: scanRoot) else { return false }
        treeGeneration += 1
        let result = entry.result
        hasFullDiskAccess = FullDiskAccess.isGranted
        scanState = .loaded(result)
        drillPath = [result.root]
        cachedAt = entry.scannedAt
        rebuildSegments()
        // Walks the whole tree; on a full volume that is hundreds of thousands of nodes.
        // Running it inline blocked the main actor while the window was already visible.
        recommendations = await Self.analyzeOffMain(result)
        return true
    }

    func scan() async {
        treeGeneration += 1
        scanState = .scanning(nil)
        refreshVolume()
        do {
            let result = try await scanner.scan(path: scanRoot) { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    if case .scanning = self.scanState { self.scanState = .scanning(progress) }
                }
            }
            scanState = .loaded(result)
            drillPath = [result.root]
            cachedAt = nil
            rebuildSegments()
            // Walks the whole tree; on a full volume that is hundreds of thousands of nodes.
        // Running it inline blocked the main actor while the window was already visible.
        recommendations = await Self.analyzeOffMain(result)
            ScanCache.shared.save(result)

            // Only raise the access prompt when it would actually change the numbers:
            // unreadable folders are the observable symptom, so a scan that hit none has
            // nothing to complain about even if the grant is technically missing.
            hasFullDiskAccess = FullDiskAccess.isGranted
            if !hasFullDiskAccess, result.inaccessibleCount > 0 {
                showingAccessSheet = true
            }
        } catch {
            scanState = .failed(error.localizedDescription)
        }
    }

    private nonisolated static func analyzeOffMain(_ result: ScanResult) async
        -> [Recommendation]
    {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: RecommendationEngine.analyze(result: result))
            }
        }
    }

    var reclaimableSafely: UInt64 {
        recommendations.filter { $0.tier == .safe }.reduce(0) { $0 &+ $1.size }
    }

    /// Moves a suggestion's target to the Trash and registers the inverse with the
    /// UndoManager, so Cmd+Z puts it straight back.
    func trash(_ recommendation: Recommendation) {
        let (trashed, failures) = TrashService.moveToTrash(paths: [recommendation.path])

        if let first = failures.first {
            lastError = first.localizedDescription
            return
        }
        guard !trashed.isEmpty else { return }

        recommendations.removeAll { $0.id == recommendation.id }

        // Same treatment as a deletion from the chart: update what we already know now, and
        // re-walk behind it. Without this the chart kept showing space that a suggestion had
        // just reclaimed.
        let components = treeComponents(forAbsolute: recommendation.path)
        let removed = components.flatMap { removeFromTree(at: $0) }
        reconcile()

        undoManager.registerUndo(withTarget: self) { model in
            let restoreFailures = TrashService.restore(trashed)
            if let failure = restoreFailures.first {
                model.lastError = failure.localizedDescription
            } else {
                model.recommendations.append(recommendation)
                model.recommendations.sort {
                    $0.tier == $1.tier ? $0.size > $1.size : $0.tier < $1.tier
                }
                if let removed, let components {
                    model.insertIntoTree(removed, at: components)
                }
                model.reconcile()
            }
        }
        undoManager.setActionName("Move \(recommendation.title) to Trash")
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }

    /// Path components from the scan root down to whatever the chart is currently centred on.
    ///
    /// The first entry of `drillPath` is the scan root itself, whose name ("Data") is not a
    /// component of any path below it.
    var rootComponents: [String] { drillPath.dropFirst().map(\.name) }

    func rebuildSegments() {
        guard let root = currentRoot else {
            segments = []
            return
        }
        segments = SunburstLayout.build(root: root, rootComponents: rootComponents)
    }

    /// Drills into a wedge, keeping every level between here and it.
    ///
    /// Takes the segment rather than its node because a node alone does not say where it
    /// sits. Wedges on the outer rings are several levels below the chart's root, and
    /// appending only the clicked node silently dropped its ancestors from `drillPath` —
    /// which is the stack that breadcrumbs, absolute paths, and category colouring are all
    /// derived from. Double-clicking `mohammadmalik` on ring 1 produced a breadcrumb reading
    /// "Data > mohammadmalik", coloured every folder under it grey because the path no longer
    /// began with `Users`, and handed `/System/Volumes/Data/mohammadmalik` to Reveal in
    /// Finder, Copy Path, and Move to Trash.
    func drillDown(into segment: SunburstSegment) {
        guard segment.node.isDirectory, !segment.node.children.isEmpty else { return }
        guard let root = currentRoot,
            let chain = root.chain(to: segment.components.dropFirst(rootComponents.count)),
            !chain.isEmpty
        else { return }
        drillPath.append(contentsOf: chain)
        selectedSegment = nil
        hoveredSegment = nil
        rebuildSegments()
    }

    func drillUp(to index: Int) {
        guard index < drillPath.count else { return }
        drillPath.removeSubrange((index + 1)...)
        selectedSegment = nil
        hoveredSegment = nil
        rebuildSegments()
    }

    /// Absolute path for a segment, rebuilt from the drill stack plus the segment's own
    /// components.
    func absolutePath(for segment: SunburstSegment) -> String {
        let base = rootComponents
        return path(joining: base + segment.components.dropFirst(base.count))
    }

    /// Absolute path of the breadcrumb entry at `index`, i.e. of `drillPath[index]`.
    func absolutePath(forDepth index: Int) -> String {
        path(joining: drillPath.prefix(index + 1).dropFirst().map(\.name))
    }

    /// A volume mounted at `/` makes `scanRoot` a lone slash, which would otherwise join into
    /// a doubled separator.
    private func path(joining components: some Sequence<String>) -> String {
        ([scanRoot] + components).joined(separator: "/")
            .replacingOccurrences(of: "//", with: "/")
    }

    func revealInFinder(_ segment: SunburstSegment) {
        reveal(path: absolutePath(for: segment))
    }

    func copyPath(_ segment: SunburstSegment) {
        copy(path: absolutePath(for: segment))
    }

    func revealInFinder(depth index: Int) {
        reveal(path: absolutePath(forDepth: index))
    }

    func copyPath(depth index: Int) {
        copy(path: absolutePath(forDepth: index))
    }

    private func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copy(path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Shows the last preview immediately, and only asks Mole again when it has gone stale.
    ///
    /// `mole clean --dry-run` takes about 98 seconds — longer than scanning the whole disk —
    /// and this used to run on every launch, which is why the bar read "Checking with Mole…"
    /// for a minute and a half while competing with the scan that had just started. Mole
    /// offers no faster way to ask, so the only lever is how often it is asked.
    func loadMoleReport() async {
        if let entry = MoleReportCache.shared.load() {
            moleReport = entry.report
            moleCheckedAt = entry.checkedAt
            guard entry.isStale else { return }
        }
        await refreshMoleReport()
    }

    /// Asks Mole again regardless of what is cached.
    ///
    /// The existing figure deliberately stays on screen while this runs. Blanking it would
    /// trade a slightly old number for no number at all, for a minute and a half.
    func refreshMoleReport() async {
        isLoadingMole = true
        defer { isLoadingMole = false }
        guard let report = try? await mole.dryRun() else { return }
        moleReport = report
        moleCheckedAt = Date()
        MoleReportCache.shared.save(report)
    }

    /// Drops the cached preview after a real cleanup, since Mole has just deleted the very
    /// things it was counting. Refreshing in the background keeps the bar from sitting on a
    /// figure that is now certainly wrong.
    func invalidateMoleReport() async {
        MoleReportCache.shared.clear()
        moleCheckedAt = nil
        await refreshMoleReport()
    }

    /// Opens the in-app cleanup terminal.
    ///
    /// This replaced an AppleScript handoff that asked Terminal.app to run `mole clean`.
    /// That call requires Automation permission; without it it blocks indefinitely, which
    /// is why the button appeared to open a terminal and then do nothing. Running Mole on a
    /// pty inside Disker needs no cross-app permission and keeps the user in one window,
    /// while still showing every confirmation Mole asks for.
    func launchMoleCleanup() {
        showingMoleSheet = true
    }

    /// Opens one of Mole's own configuration screens (whitelist, project paths) in the
    /// embedded terminal. These are interactive editors; reimplementing them in Disker would
    /// mean writing to Mole's config format behind its back.
    func runMoleSettings(argument: String) {
        moleSession.runRaw(
            arguments: [moleConfiguration.operation.rawValue, argument],
            label: moleConfiguration.operation)
        moleShowingTerminal = true
        showingMoleSheet = true
    }

    func chooseExternalVolume() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            moleConfiguration.externalVolumePath = url.path
        }
    }

    /// Jumps the chart to a top-level folder.
    ///
    /// Deliberately leaves `section` alone. Setting it back to `.overview` here would fight
    /// the sidebar selection that triggered this, so the highlight would snap away from the
    /// location the user just picked. The detail view renders `.location` and `.overview`
    /// identically — the difference is only which row stays selected.
    func openLocation(named name: String) {
        guard case .loaded(let result) = scanState,
            let node = result.root.children.first(where: { $0.name == name })
        else { return }
        drillPath = [result.root, node]
        selectedSegment = nil
        hoveredSegment = nil
        rebuildSegments()
    }

    /// Asks before moving a scanned item to the Trash.
    ///
    /// Deletion from the chart is confirmed rather than immediate: a wedge is a small target,
    /// clicks there are exploratory, and the sizes involved run to gigabytes.
    func requestDeletion(of segment: SunburstSegment) {
        pendingDeletion = (
            path: absolutePath(for: segment),
            name: segment.node.name,
            size: segment.node.size,
            // Carried through the confirmation so the tree edit afterwards does not have to
            // re-derive the position by parsing the absolute path back apart.
            components: segment.components
        )
    }

    /// Performs the confirmed deletion, registering undo.
    func confirmDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil

        let (trashed, failures) = TrashService.moveToTrash(paths: [pending.path])
        if let failure = failures.first {
            lastError = failure.localizedDescription
            return
        }
        guard !trashed.isEmpty else { return }

        // The chart updates now, from what we already know: the item is gone and every
        // folder above it is smaller by exactly its size. Re-walking the volume is the only
        // way to learn what *else* changed, so it still happens — in the background, without
        // a spinner over numbers that are already correct for this edit.
        let removed = removeFromTree(at: pending.components)
        reconcile()

        undoManager.registerUndo(withTarget: self) { model in
            let restoreFailures = TrashService.restore(trashed)
            if let failure = restoreFailures.first {
                model.lastError = failure.localizedDescription
                return
            }
            if let removed {
                model.insertIntoTree(removed, at: pending.components)
            }
            model.reconcile()
        }
        undoManager.setActionName("Move \(pending.name) to Trash")
    }

    // MARK: - Keeping the tree current

    /// Whether a background re-walk is running behind an already-updated chart.
    private(set) var isReconciling = false

    /// Splits an absolute path into components relative to the scan root.
    ///
    /// `nil` when the path lies outside the tree currently on screen — a suggestion on
    /// another volume, say — in which case there is nothing local to edit and the background
    /// pass is the whole update.
    private func treeComponents(forAbsolute path: String) -> [String]? {
        guard path.hasPrefix(scanRoot) else { return nil }
        let components = path.dropFirst(scanRoot.count).split(separator: "/").map(String.init)
        return components.isEmpty ? nil : components
    }

    /// Drops the node at `components` and returns it, so undo can put it back.
    @discardableResult
    private func removeFromTree(at components: [String]) -> FileNode? {
        guard case .loaded(let result) = scanState,
            let (root, removed) = result.root.removingDescendant(at: components)
        else { return nil }

        // Anything suggested from inside what was just deleted is gone too. The background
        // pass recomputes these properly; this only stops the list advertising a path that
        // no longer exists in the meantime.
        let deleted = path(joining: components)
        recommendations.removeAll { $0.path == deleted || $0.path.hasPrefix(deleted + "/") }

        adopt(root: root, from: result)
        return removed
    }

    private func insertIntoTree(_ node: FileNode, at components: [String]) {
        guard case .loaded(let result) = scanState,
            let root = result.root.insertingDescendant(node, at: components)
        else { return }
        adopt(root: root, from: result)
    }

    /// Swaps in an edited tree, keeping the chart where the user left it.
    ///
    /// `drillPath` holds node references, and the edit rebuilt the spine, so those have to be
    /// re-resolved by name or the breadcrumb keeps pointing at the pre-edit objects.
    private func adopt(root: FileNode, from previous: ScanResult) {
        let components = rootComponents
        scanState = .loaded(
            ScanResult(
                root: root,
                rootPath: previous.rootPath,
                duration: previous.duration,
                inaccessibleCount: previous.inaccessibleCount,
                deduplicatedBytes: previous.deduplicatedBytes))
        drillPath = [root] + (root.chain(to: components) ?? [])
        selectedSegment = nil
        hoveredSegment = nil
        rebuildSegments()
        refreshVolume()
    }

    /// Re-walks the volume behind the current chart and swaps the result in when it lands.
    ///
    /// Deliberately does not touch `scanState` on the way in. Setting `.scanning` would
    /// replace a chart that is already right about the edit with a progress spinner, which
    /// is the delay this exists to avoid. A failure is swallowed for the same reason: the
    /// locally edited tree is still closer to the truth than the pre-deletion one.
    /// One pass at a time, with a second request remembered rather than started.
    ///
    /// Cancelling would not help: `VolumeScanner.scan` does its traversal inside a checked
    /// continuation and never observes cancellation, so a cancelled task keeps walking the
    /// volume regardless. Deleting several things in a row would then have a full walk
    /// running for each, saturating the disk for minutes while the chart looked idle.
    private func reconcile() {
        guard reconcileTask == nil else {
            reconcileQueued = true
            return
        }
        isReconciling = true
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            await runReconcilePass()
            reconcileTask = nil
            if reconcileQueued {
                reconcileQueued = false
                reconcile()
            } else {
                isReconciling = false
            }
        }
    }

    private func runReconcilePass() async {
        // What this pass is a re-walk *of*. A full scan takes seconds, and the window can
        // move to another volume in that time — publishing then would file one disk's tree
        // under another disk's name, with the picker and the free-space bar still naming the
        // new one.
        let generation = treeGeneration
        let root = scanRoot

        guard let result = try? await scanner.scan(path: root, onProgress: { _ in }),
            generation == treeGeneration, root == scanRoot
        else { return }

        // Checked again after the analysis, which is another trip off the main actor. A
        // deletion or an undo landing in that window would otherwise be undone here: stale
        // recommendations reassigned, and a stale tree written to the cache.
        let analyzed = await Self.analyzeOffMain(result)
        guard generation == treeGeneration, root == scanRoot else { return }

        let components = rootComponents
        scanState = .loaded(result)
        drillPath = [result.root] + (result.root.chain(to: components) ?? [])
        cachedAt = nil
        selectedSegment = nil
        hoveredSegment = nil
        rebuildSegments()
        recommendations = analyzed
        ScanCache.shared.save(result)
        refreshVolume()
    }
}
