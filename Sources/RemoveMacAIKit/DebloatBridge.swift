import SwiftUI
import UAF

// The one Disker-owned file in this module. Everything under `Upstream/` is RemoveMacAI as
// released and is replaced wholesale by Tools/sync-removemacai.sh, so it stays internal and
// this file is the only surface Disker sees. Keep it small: each upstream name used here is
// one more thing a resync can break.

/// RemoveMacAI's own window contents, hosted inside Disker.
public struct DebloatView: View {
    /// Made once, on first appearance — not in `init`. SwiftUI re-runs `init` every time
    /// the scene is re-evaluated, which in Disker is whenever the sidebar badge or the
    /// update check changes, and `@State` only keeps the first value. Upstream's `AppModel`
    /// reads launchd, the Dock and the asset service as it is made, so each discarded copy
    /// repeated that work and raced the live one over the asset service's cache.
    @State private var model: AppModel?

    public init() {}

    public var body: some View {
        Group {
            if let model {
                ContentView()
                    .environment(model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            guard model == nil else { return }
            // Upstream's entry point sets this before showing its window. Without it an
            // administrator step looks for a terminal to run sudo in, and an app has none.
            Shell.inApp = true
            model = AppModel()
        }
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
    ///
    /// Reads the inventory directly rather than through `Models.bytes`. That goes through
    /// `Models.inventory()`, whose cache is an unsynchronized static, and the Debloat
    /// window's own model reads the same cache from a detached task — at launch, when the
    /// window is restored, both run at once. `parseInventory` is pure, so this shares
    /// nothing with upstream's state. It also skips upstream's per-set fallback for when
    /// the inventory is missing, and reports unknown instead.
    public static func modelBytesOnDisk() async -> UInt64? {
        await Task.detached(priority: .utility) {
            guard Models.available() else { return nil }
            var error: NSError?
            guard let info = UAFInformation(&error) as? [String: Any] else { return nil }
            let inventory = Models.parseInventory(info)
            let total = Catalog.availableModelSets.reduce(Int64(0)) { $0 + (inventory[$1.assetType] ?? 0) }
            return UInt64(max(0, total))
        }.value
    }
}
