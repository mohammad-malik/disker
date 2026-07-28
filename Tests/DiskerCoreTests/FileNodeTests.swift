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
