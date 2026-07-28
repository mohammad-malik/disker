import Foundation

/// Moves files to the Trash, and puts them back.
///
/// Every deletion path in Disker goes through here. Nothing calls `unlink` or
/// `removeItem` — a disk analyzer is used precisely when someone is under pressure to free
/// space quickly, which is exactly when an irreversible delete does real damage. The Trash
/// keeps the decision reversible both through Disker's own undo and through Finder.
public enum TrashService {

    public struct TrashedItem: Sendable {
        public let originalPath: String
        /// Where it landed in the Trash — the anchor undo uses to put it back.
        public let trashedURL: URL
    }

    public enum TrashError: Error, LocalizedError {
        case failed(path: String, underlying: String)
        case restoreFailed(path: String, underlying: String)

        public var errorDescription: String? {
            switch self {
            case .failed(let path, let reason):
                return "Could not move \(path) to the Trash: \(reason)"
            case .restoreFailed(let path, let reason):
                return "Could not restore \(path): \(reason)"
            }
        }
    }

    /// Moves items to the Trash, returning enough information to undo it.
    ///
    /// Partial success is deliberate: if one of twenty items is locked, the other nineteen
    /// still move and the failure is reported. Rolling the whole batch back would be a
    /// worse outcome than a partial clean-up the user can see.
    public static func moveToTrash(paths: [String]) -> (
        trashed: [TrashedItem], failures: [TrashError]
    ) {
        var trashed: [TrashedItem] = []
        var failures: [TrashError] = []

        for path in paths {
            let url = URL(fileURLWithPath: path)
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                if let destination = resulting as URL? {
                    trashed.append(TrashedItem(originalPath: path, trashedURL: destination))
                }
            } catch {
                failures.append(.failed(path: path, underlying: error.localizedDescription))
            }
        }
        return (trashed, failures)
    }

    /// Moves items back where they came from.
    public static func restore(_ items: [TrashedItem]) -> [TrashError] {
        var failures: [TrashError] = []
        for item in items {
            let destination = URL(fileURLWithPath: item.originalPath)
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: item.trashedURL, to: destination)
            } catch {
                failures.append(
                    .restoreFailed(path: item.originalPath, underlying: error.localizedDescription))
            }
        }
        return failures
    }
}

/// Detects whether the app holds Full Disk Access.
///
/// This matters more than it looks. Without the grant a non-sandboxed app does not get a
/// permission prompt — protected directories simply return `EPERM`, the scan completes, and
/// the reported total is quietly tens of gigabytes short with nothing on screen to explain
/// why. Detecting it lets the app say so instead of showing a confidently wrong number.
public enum FullDiskAccess {

    /// Readable only with the grant, and reading it triggers no prompt.
    private static var probePath: String {
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
    }

    public static var isGranted: Bool {
        let fd = open(probePath, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        // ENOENT would mean the probe file is missing rather than blocked, so only a
        // permission error counts as "not granted".
        return errno != EPERM && errno != EACCES
    }

    /// Deep link to the exact Settings pane, so the user is not left hunting for it.
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
