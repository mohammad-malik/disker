import Foundation
import Testing

@testable import DiskerCore

@Suite("Sunburst layout")
struct SunburstLayoutTests {

    private func tree() -> FileNode {
        FileNode(
            name: "root", size: 1000, kind: .directory,
            children: [
                FileNode(
                    name: "big", size: 600, kind: .directory,
                    children: [
                        FileNode(name: "inner-a", size: 400, kind: .file),
                        FileNode(name: "inner-b", size: 200, kind: .file),
                    ], fileCount: 2),
                FileNode(name: "medium", size: 300, kind: .file),
                FileNode(name: "small", size: 100, kind: .file),
            ], fileCount: 4)
    }

    @Test("Innermost ring spans the full circle")
    func firstRingIsComplete() {
        let segments = SunburstLayout.build(root: tree())
        let ringZero = segments.filter { $0.ring == 0 }
        let total = ringZero.reduce(0.0) { $0 + $1.sweep }

        // Gaps in the ring would misrepresent how much of the parent each child occupies.
        #expect(abs(total - 2 * .pi) < 0.0001)
    }

    @Test("Wedge angle is proportional to size")
    func anglesAreProportional() {
        let segments = SunburstLayout.build(root: tree())
        let big = try! #require(segments.first { $0.node.name == "big" })

        // 600 of 1000 bytes → 60% of the circle.
        #expect(abs(big.sweep - 2 * .pi * 0.6) < 0.0001)
    }

    @Test("Children are nested inside their parent's arc")
    func childrenStayWithinParent() {
        let segments = SunburstLayout.build(root: tree())
        let big = try! #require(segments.first { $0.node.name == "big" })
        let inner = segments.filter { $0.ring == 1 && $0.node.name.hasPrefix("inner") }

        #expect(inner.count == 2)
        for child in inner {
            #expect(child.startAngle >= big.startAngle - 0.0001)
            #expect(child.endAngle <= big.endAngle + 0.0001)
        }
    }

    @Test("Ring depth is capped")
    func ringsAreCapped() {
        // A chain deeper than the cap; rings past the limit would be a few points wide.
        var node = FileNode(name: "leaf", size: 100, kind: .file)
        for level in 0..<10 {
            node = FileNode(
                name: "level\(level)", size: 100, kind: .directory, children: [node], fileCount: 1)
        }
        let root = FileNode(name: "root", size: 100, kind: .directory, children: [node], fileCount: 1)

        let options = SunburstLayout.Options(maxRings: 3)
        let segments = SunburstLayout.build(root: root, options: options)

        #expect(segments.allSatisfy { $0.ring < 3 })
    }

    @Test("Slivers are merged rather than dropped")
    func tinySegmentsAreMerged() {
        // 500 files of 1 byte each against one large file: individually each is far below
        // the minimum angle, but together they are a third of the parent.
        var children = [FileNode(name: "huge", size: 1000, kind: .file)]
        children += (0..<500).map { FileNode(name: "tiny\($0)", size: 1, kind: .file) }
        let root = FileNode(
            name: "root", size: 1500, kind: .directory, children: children, fileCount: 501)

        let segments = SunburstLayout.build(root: root)
        let ringZero = segments.filter { $0.ring == 0 }

        // Dropping them would leave a third of the ring blank and overstate "huge".
        #expect(ringZero.count < 100)
        #expect(abs(ringZero.reduce(0.0) { $0 + $1.sweep } - 2 * .pi) < 0.0001)
        #expect(ringZero.contains { $0.node.kind == .aggregate })
    }

    @Test("Hit testing maps points back to the wedge under them")
    func hitTestingFindsSegments() {
        let segments = SunburstLayout.build(root: tree())
        let innerRadius = 50.0
        let ringWidth = 40.0

        // Straight up from centre is angle 0, inside the first wedge of ring 0.
        let hit = SunburstLayout.segment(
            at: (x: 0, y: -70), in: segments,
            innerRadius: innerRadius, ringWidth: ringWidth)

        #expect(hit?.node.name == "big")
    }

    @Test("Points inside the hub hit nothing")
    func hubIsNotHitTested() {
        let segments = SunburstLayout.build(root: tree())
        let hit = SunburstLayout.segment(
            at: (x: 5, y: 5), in: segments, innerRadius: 50, ringWidth: 40)

        // The hub is its own control (go up a level), so it must not report a wedge.
        #expect(hit == nil)
    }

    @Test("Categories are assigned from the path, not the name")
    func categoryClassification() {
        #expect(StorageCategory.classify(components: ["Applications"]) == .applications)
        #expect(StorageCategory.classify(components: ["Users", "alex", "Pictures"]) == .pictures)
        #expect(StorageCategory.classify(components: ["Users", "alex", "Downloads"]) == .documents)
        #expect(StorageCategory.classify(components: ["Users", "alex"]) == .users)
        #expect(StorageCategory.classify(components: ["System"]) == .system)
    }
}
