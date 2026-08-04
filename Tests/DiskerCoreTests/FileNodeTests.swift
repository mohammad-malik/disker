import Foundation
import Testing

@testable import DiskerCore

@Suite("FileNode aggregation")
struct FileNodeTests {

    @Test("Aggregation preserves total size and file count exactly")
    func aggregationPreservesTotals() {
        let options = ScanOptions(smallFileThreshold: 1000, maxChildrenPerDirectory: 10)
        let children = (0..<50).map {
            FileNode(name: "f\($0)", size: UInt64($0) * 100, kind: .file)
        }
        let expectedBytes = children.reduce(UInt64(0)) { $0 + $1.size }

        let dir = FileNode.directory(name: "d", rawChildren: children, options: options)

        // The whole point of folding: the chart gets fewer nodes, the numbers stay exact.
        #expect(dir.size == expectedBytes)
        #expect(dir.fileCount == 50)
        #expect(dir.children.count <= options.maxChildrenPerDirectory + 1)
    }

    @Test("Directories survive folding even when small")
    func directoriesAreNeverFolded() {
        let options = ScanOptions(smallFileThreshold: 10_000)
        let children = [
            FileNode(name: "tiny-dir", size: 1, kind: .directory),
            FileNode(name: "tiny-file", size: 1, kind: .file),
        ]

        let dir = FileNode.directory(name: "d", rawChildren: children, options: options)

        // Directories carry the structure the sunburst is drawn from; folding them would
        // punch holes in the chart's hierarchy.
        #expect(dir.children.contains { $0.name == "tiny-dir" })
        #expect(!dir.children.contains { $0.name == "tiny-file" })
    }

    @Test("Children are ordered largest first")
    func childrenSortedBySize() {
        let options = ScanOptions(smallFileThreshold: 0)
        let children = [
            FileNode(name: "small", size: 10, kind: .file),
            FileNode(name: "big", size: 1000, kind: .file),
            FileNode(name: "medium", size: 500, kind: .file),
        ]

        let dir = FileNode.directory(name: "d", rawChildren: children, options: options)

        #expect(dir.children.map(\.name) == ["big", "medium", "small"])
    }

    /// Drilling into an outer ring jumps several levels at once, and every level has to
    /// arrive in the drill stack. When only the clicked node was appended, the chart lost
    /// track of where it was: the breadcrumb skipped a folder, categories were classified
    /// from a path missing its prefix so a home directory came out entirely grey, and the
    /// absolute path handed to Reveal in Finder and Move to Trash pointed at nothing.
    @Test("Descending a path yields every level, not just the destination")
    func chainKeepsIntermediateLevels() throws {
        let library = FileNode(
            name: "Library", size: 300, kind: .directory,
            children: [FileNode(name: "Caches", size: 300, kind: .directory)], fileCount: 1)
        let home = FileNode(
            name: "alex", size: 300, kind: .directory, children: [library], fileCount: 1)
        let users = FileNode(
            name: "Users", size: 300, kind: .directory, children: [home], fileCount: 1)
        let root = FileNode(
            name: "Data", size: 300, kind: .directory, children: [users], fileCount: 1)

        let chain = try #require(root.chain(to: ["Users", "alex", "Library"]))

        #expect(chain.map(\.name) == ["Users", "alex", "Library"])
        // A grey home directory was exactly this: classifying ["alex", ...] rather than
        // ["Users", "alex", ...], which falls through to `.other` for everything.
        #expect(StorageCategory.classify(components: chain.map(\.name)) == .system)
    }

    @Test("Descending an empty path stays where it is")
    func chainOfNothing() {
        let root = FileNode(name: "Data", size: 0, kind: .directory)
        #expect(root.chain(to: [String]())?.isEmpty == true)
    }

    /// Happens when a re-scan replaces the tree while a wedge from the old one is selected.
    /// Returning a partial chain would drill somewhere the user did not click.
    @Test("A path that no longer exists resolves to nothing")
    func chainRejectsMissingComponents() {
        let users = FileNode(name: "Users", size: 100, kind: .directory)
        let root = FileNode(
            name: "Data", size: 100, kind: .directory, children: [users], fileCount: 1)

        #expect(root.chain(to: ["Users", "gone"]) == nil)
        #expect(root.chain(to: ["Applications"]) == nil)
    }

    @Test("Inaccessible directories are counted through the tree")
    func inaccessibleCountPropagates() {
        let blocked = FileNode(name: "blocked", size: 0, kind: .directory, flags: .inaccessible)
        let nested = FileNode(
            name: "nested", size: 0, kind: .directory, children: [blocked], fileCount: 0)
        let root = FileNode(
            name: "root", size: 0, kind: .directory, children: [nested, blocked], fileCount: 0)

        #expect(root.inaccessibleCount == 2)
    }
}
