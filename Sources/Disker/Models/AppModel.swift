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

    enum Section: String, Hashable, CaseIterable, Identifiable {
        case overview = "Storage Overview"
        case recommendations = "Recommendations"

        var id: String { rawValue }
        var symbolName: String {
            switch self {
            case .overview: return "chart.pie.fill"
            case .recommendations: return "sparkles"
            }
        }
    }

    var section: Section = .overview
    var scanState: ScanState = .idle
    var volume: VolumeInfo?
    var moleReport: MoleReport?
    var isLoadingMole = false

    /// Nodes from the scan root down to whatever the chart is currently centred on.
    /// Doubles as the breadcrumb and as the source of full paths, which is why nodes
    /// themselves carry no parent pointer.
    var drillPath: [FileNode] = []

    var hoveredSegment: SunburstSegment?
    var selectedSegment: SunburstSegment?

    var recommendations: [Recommendation] = []
    var hasFullDiskAccess = true
    var showingAccessSheet = false
    /// Surfaced inline rather than as a modal alert — a failed delete is information,
    /// not a decision the user has to stop and make.
    var lastError: String?

    /// Drives Cmd+Z. Held here rather than on a view so undo survives selection changes.
    let undoManager = UndoManager()

    private let scanner = VolumeScanner()
    private let mole = MoleClient()

    /// The data volume, not `/`. The sealed system volume is ~12 GB of immutable OS that a
    /// user can neither browse nor reclaim, so rooting the chart there would show them
    /// almost nothing they care about.
    var scanRoot = "/System/Volumes/Data"

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
    func loadCachedScan() -> Bool {
        guard let entry = ScanCache.load(expecting: scanRoot) else { return false }
        let result = entry.result
        scanState = .loaded(result)
        drillPath = [result.root]
        cachedAt = entry.scannedAt
        rebuildSegments()
        recommendations = RecommendationEngine.analyze(result: result)
        return true
    }

    func scan() async {
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
            recommendations = RecommendationEngine.analyze(result: result)
            ScanCache.save(result)

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

        undoManager.registerUndo(withTarget: self) { model in
            let restoreFailures = TrashService.restore(trashed)
            if let failure = restoreFailures.first {
                model.lastError = failure.localizedDescription
            } else {
                model.recommendations.append(recommendation)
                model.recommendations.sort {
                    $0.tier == $1.tier ? $0.size > $1.size : $0.tier < $1.tier
                }
            }
        }
        undoManager.setActionName("Move \(recommendation.title) to Trash")
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }

    func rebuildSegments() {
        guard let root = currentRoot else {
            segments = []
            return
        }
        segments = SunburstLayout.build(
            root: root,
            rootComponents: drillPath.dropFirst().map(\.name)
        )
    }

    func drillDown(into node: FileNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        drillPath.append(node)
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
        let base = drillPath.dropFirst().map(\.name)
        let combined = base + segment.components.dropFirst(base.count)
        return ([scanRoot] + combined).joined(separator: "/").replacingOccurrences(
            of: "//", with: "/")
    }

    func revealInFinder(_ segment: SunburstSegment) {
        let path = absolutePath(for: segment)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyPath(_ segment: SunburstSegment) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(absolutePath(for: segment), forType: .string)
    }

    func loadMoleReport() async {
        isLoadingMole = true
        defer { isLoadingMole = false }
        moleReport = try? await mole.dryRun()
    }

    /// Hands off to Mole in Terminal.
    ///
    /// Deliberately not silent: `mole clean` is an interactive TUI with no headless mode, and
    /// a full clean needs sudo. Driving it from a privileged helper would mean bypassing the
    /// confirmations Mole shows before deleting, so the user reviews and authorises in the
    /// terminal where those prompts actually appear.
    func launchMoleCleanup() {
        let script = """
            tell application "Terminal"
                activate
                do script "mole clean"
            end tell
            """
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }
}
