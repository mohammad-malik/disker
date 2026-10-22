import SwiftUI

// The one Disker-owned file in this module. Everything under `Upstream/` is RemoveMacAI as
// released and is replaced wholesale by Tools/sync-removemacai.sh, so it stays internal and
// this file is the only surface Disker sees. Keep it small: each upstream name used here is
// one more thing a resync can break.

/// RemoveMacAI's own window contents, hosted inside Disker.
public struct DebloatView: View {
    @State private var model: AppModel

    public init() {
        // Upstream's entry point sets this before showing its window. Without it an
        // administrator step looks for a terminal to run sudo in, and an app has none.
        Shell.inApp = true
        _model = State(initialValue: AppModel())
    }

    public var body: some View {
        ContentView()
            .environment(model)
    }
}

public enum Debloat {
    /// The vendored release, for the About line.
    public static let upstreamVersion = version

    /// Bytes of Apple Intelligence models on disk, or nil when Apple's asset service does
    /// not answer. This is the number that tells someone opening a disk tool why the
    /// Debloat window is worth a look, so the sidebar and Recommendations both show it.
    ///
    /// Asks the asset service in process, which can take a second; never call it on the
    /// main actor.
    public static func modelBytesOnDisk() async -> UInt64? {
        await Task.detached(priority: .utility) {
            guard Models.available() else { return nil }
            return Models.total(Catalog.availableModelSets.map(\.name)).map { UInt64(max(0, $0)) }
        }.value
    }
}
