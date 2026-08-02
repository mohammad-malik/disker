import Foundation

/// Persists Mole's last cleanup preview, so opening the app shows numbers instead of a
/// spinner.
///
/// `mole clean --dry-run` is the single slowest thing Disker does — **98 seconds** measured
/// against Mole 1.43.1, far longer than a full-volume scan of the same disk. It was run on
/// every launch, so "Checking with Mole…" sat there for a minute and a half while the work
/// competed with the scan that had just started.
///
/// There is no cheaper way to ask. Mole exposes no JSON form of the preview, and its other
/// subcommands answer different questions: `analyze` explores disk usage, which Disker
/// already does itself, and `history --json` reports past cleanups rather than a forecast.
/// So the cost is inherent and the only real lever is how often it is paid.
///
/// What it measures also moves slowly — caches and build artifacts accumulate over days, not
/// minutes — so a preview from this morning is a perfectly good answer this afternoon. The
/// cached figure is shown immediately with its age, and refreshed only when it is stale or
/// when the user asks.
///
/// The storage directory is injectable so tests exercise a temporary one, for the same
/// reason `ScanCache`'s is: a suite that writes to Application Support would trample the real
/// cache.
public struct MoleReportCache: Sendable {

    /// How long a preview stays good enough to show without re-running Mole.
    ///
    /// A day is chosen because that is roughly the timescale on which the things Mole
    /// reclaims — caches, logs, stale build output — actually change. Anything much shorter
    /// re-imposes the 98-second cost for numbers that would barely move.
    public static let freshnessWindow: TimeInterval = 24 * 60 * 60

    public struct Entry: Codable, Sendable {
        public let report: MoleReport
        public let checkedAt: Date

        public var age: TimeInterval { Date().timeIntervalSince(checkedAt) }

        /// A preview old enough to be worth re-running in the background.
        public var isStale: Bool { age > MoleReportCache.freshnessWindow }
    }

    private let directory: URL?

    public init(directory: URL?) {
        self.directory = directory
    }

    /// The cache the app uses, alongside the scan cache.
    public static let shared = MoleReportCache(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Disker", isDirectory: true))

    private var fileURL: URL? {
        directory?.appendingPathComponent("mole-report.plist")
    }

    public func save(_ report: MoleReport) {
        // An unparseable result is a statement about Mole's output format, not about the
        // disk. Caching it would keep showing "couldn't read Mole's output" for a day after
        // a transient failure, and would suppress the retry that might well succeed.
        guard case .parsed = report else { return }
        guard let directory, let fileURL else { return }

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let entry = Entry(report: report, checkedAt: Date())
            try encoder.encode(entry).write(to: fileURL, options: .atomic)
        } catch {
            // A miss costs one re-run, nothing more — never surface this to the user.
        }
    }

    public func load() -> Entry? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let entry = try? PropertyListDecoder().decode(Entry.self, from: data) else {
            // Most likely written by an older build. Drop it rather than fail, so one stale
            // file cannot break every future launch.
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return entry
    }

    /// Discards the cached preview, so the next load asks Mole again.
    ///
    /// Called after a real cleanup run: Mole has just deleted the very things the preview
    /// was counting, so continuing to advertise that space would be actively wrong.
    public func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Path of the backing file, for tests that need to corrupt it deliberately.
    public var storageURL: URL? { fileURL }
}
