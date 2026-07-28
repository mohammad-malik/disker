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

    private let scanner = VolumeScanner()
    private let mole = MoleClient()

    /// The data volume, not `/`. The sealed system volume is ~12 GB of immutable OS that a
    /// user can neither browse nor reclaim, so rooting the chart there would show them
    /// almost nothing they care about.
    var scanRoot = "/System/Volumes/Data"

    var currentRoot: FileNode? { drillPath.last }

    var breadcrumb: [FileNode] { drillPath }

    var segments: [SunburstSegment] = []

    func refreshVolume() {
        volume = VolumeInfo.current(for: scanRoot)
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
            rebuildSegments()
        } catch {
            scanState = .failed(error.localizedDescription)
        }
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
