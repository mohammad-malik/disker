import Foundation
import Testing

@testable import DiskerCore

@Suite("Editing a scanned tree")
struct FileNodeEditingTests {

    /// Users/
    ///   me/
    ///     Library/  (300)
    ///     Docs/     (200)
    ///   shared/     (100)
    private func sample() -> FileNode {
        let library = FileNode(name: "Library", size: 300, kind: .directory, fileCount: 3)
        let docs = FileNode(name: "Docs", size: 200, kind: .directory, fileCount: 2)
        let me = FileNode(
            name: "me", size: 500, kind: .directory, children: [library, docs], fileCount: 5)
        let shared = FileNode(name: "shared", size: 100, kind: .directory, fileCount: 1)
        return FileNode(
            name: "Users", size: 600, kind: .directory, children: [me, shared], fileCount: 6)
    }

    @Test("Removing a nested node shrinks every folder above it by exactly its size")
    func removalUpdatesAncestors() throws {
        let (root, removed) = try #require(sample().removingDescendant(at: ["me", "Library"]))

        #expect(removed.name == "Library")
        #expect(removed.size == 300)

        // 600 - 300 at the root, 500 - 300 at the parent, and the sibling untouched.
        #expect(root.size == 300)
        #expect(root.fileCount == 3)
        let me = try #require(root.children.first { $0.name == "me" })
        #expect(me.size == 200)
        #expect(me.children.map(\.name) == ["Docs"])
        #expect(root.children.first { $0.name == "shared" }?.size == 100)
    }

    @Test("Untouched subtrees are shared rather than rebuilt")
    func removalSharesUntouchedSubtrees() throws {
        let original = sample()
        let shared = try #require(original.children.first { $0.name == "shared" })
        let (root, _) = try #require(original.removingDescendant(at: ["me", "Library"]))

        // The point of rebuilding only the spine: editing one leaf on a full volume must not
        // copy hundreds of thousands of nodes.
        #expect(root.children.first { $0.name == "shared" } === shared)
    }

    @Test("Re-inserting restores the totals exactly, so undo cannot drift")
    func insertionIsTheInverseOfRemoval() throws {
        let original = sample()
        let (afterRemoval, removed) = try #require(
            original.removingDescendant(at: ["me", "Library"]))
        let restored = try #require(
            afterRemoval.insertingDescendant(removed, at: ["me", "Library"]))

        #expect(restored.size == original.size)
        #expect(restored.fileCount == original.fileCount)
        let me = try #require(restored.children.first { $0.name == "me" })
        #expect(me.size == 500)
        #expect(Set(me.children.map(\.name)) == ["Library", "Docs"])
    }

    @Test("A path that no longer resolves reports no edit rather than a wrong one")
    func unresolvablePathIsRejected() {
        #expect(sample().removingDescendant(at: ["me", "Missing"]) == nil)
        #expect(sample().removingDescendant(at: ["nobody", "Library"]) == nil)
        #expect(sample().removingDescendant(at: []) == nil)
    }

    @Test("Re-inserting something already present does not double-count it")
    func insertionIsIdempotent() throws {
        // A background rescan can land before an undo does. Adding the node a second time
        // would inflate every folder above it.
        let original = sample()
        let docs = try #require(
            original.children.first { $0.name == "me" }?.children.first { $0.name == "Docs" })
        let unchanged = try #require(original.insertingDescendant(docs, at: ["me", "Docs"]))

        #expect(unchanged.size == original.size)
        #expect(unchanged.fileCount == original.fileCount)
    }
}
