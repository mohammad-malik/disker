import Foundation

/// Persists the last scan so the window opens with data instead of a progress spinner.
///
/// A full volume scan takes anywhere from 35 seconds to several minutes depending on how
/// busy the machine is. Making the user sit through that on every launch — to see numbers
/// that barely moved since yesterday — is the wrong default. The cache is shown immediately
/// and labelled with its age, and re-scanning stays an explicit action (⌘R).
///
/// Deliberately not auto-refreshed on launch: silently re-walking two million files in the
/// background is exactly the kind of thing that makes a disk utility itself the reason the
/// fans are running.
///
/// The storage directory is injectable so tests exercise a temporary one. The first version
/// hard-coded Application Support, which meant running the suite deleted the user's real
/// cached scan — a test that destroys production data is a bug regardless of whether it passes.
public struct ScanCache: Sendable {

    public struct Entry: Codable, Sendable {
        public let root: FileNode
        public let rootPath: String
        public let scannedAt: Date
        public let duration: TimeInterval
        public let inaccessibleCount: Int
        public let deduplicatedBytes: UInt64

        public var result: ScanResult {
            ScanResult(
                root: root, rootPath: rootPath, duration: duration,
                inaccessibleCount: inaccessibleCount, deduplicatedBytes: deduplicatedBytes)
        }
    }

    private let directory: URL?

    public init(directory: URL?) {
        self.directory = directory
    }

    /// The cache the app uses, under Application Support.
    public static let shared = ScanCache(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Disker", isDirectory: true))

    private var fileURL: URL? {
        directory?.appendingPathComponent("last-scan.plist")
    }

    /// Binary property list rather than JSON: the retained tree runs to a few hundred
    /// thousand nodes, and a text format spends most of the time on string escaping.
    public func save(_ result: ScanResult) {
        guard let directory, let fileURL else { return }
        let entry = Entry(
            root: result.root,
            rootPath: result.rootPath,
            scannedAt: Date(),
            duration: result.duration,
            inaccessibleCount: result.inaccessibleCount,
            deduplicatedBytes: result.deduplicatedBytes)

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(entry).write(to: fileURL, options: .atomic)
        } catch {
            // A cache miss costs a re-scan, nothing more — never surface this to the user.
        }
    }

    public func load(expecting rootPath: String) -> Entry? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let entry = try? PropertyListDecoder().decode(Entry.self, from: data) else {
            // Most likely a tree written by an older build. Drop it rather than fail, so a
            // stale file cannot break every future launch.
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        // A cache for a different volume would be actively misleading.
        return entry.rootPath == rootPath ? entry : nil
    }

    public func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Path of the backing file, for tests that need to corrupt it deliberately.
    public var storageURL: URL? { fileURL }
}
