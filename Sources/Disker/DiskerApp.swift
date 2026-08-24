import AppKit
import DiskerCore
import SwiftUI

@main
struct DiskerApp: App {
    @State private var model = AppModel()
    @State private var appearance = AppearanceController()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, appearance: appearance)
                .frame(minWidth: 940, minHeight: 620)
                .task { appearance.start() }
        }
        .defaultSize(width: 1360, height: 880)
        // No `.hiddenTitleBar`: a standard window is what gets the floating glass toolbar,
        // the inset glass sidebar, and Tahoe's larger concentric corners. Hiding the titlebar
        // suppressed all three, which is why none of the real material was visible.
        .windowToolbarStyle(.unified)
        .commands { DiskerCommands(model: model, appearance: appearance) }

        Settings { SettingsView(model: model, appearance: appearance) }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @Bindable var appearance: AppearanceController

    var body: some View {
        // AppKit, not `NavigationSplitView` — see `SplitShell` for the four SwiftUI
        // routes to behind-window translucency that all ended up under an opaque pane.
        // Reading the two properties here — rather than inside the representable — is what
        // registers them as dependencies of this body, so the column actually moves when the
        // toolbar button or the ⌃⌘I menu item flips the preference.
        SplitShell(
            model: model,
            inspectorVisible: model.showsInspector && model.sectionSupportsInspector)
        .navigationTitle(model.volume?.name ?? "Disker")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .task {
            model.refreshVolumes()
            model.refreshVolume()
            // Show the previous scan instantly when there is one. Only walk the disk when
            // there is nothing to show — an empty window with a "Scan" button asks the user
            // to confirm the one thing they opened the app to do, but a three-minute spinner
            // over numbers that barely moved since yesterday is no better.
            if await !model.loadCachedScan() {
                await model.scan()
            }
            await model.loadMoleReport()
        }
        // A cleanup run deletes the very things the cached preview was counting, so the
        // figure is re-taken once the sheet closes rather than left advertising space that
        // has already been freed.
        .sheet(isPresented: $model.showingMoleSheet, onDismiss: {
            Task { await model.invalidateMoleReport() }
        }) {
            MoleCleanupSheet(model: model)
        }
        .confirmationDialog(
            "Move to Trash?",
            isPresented: .init(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.pendingDeletion = nil } })
        ) {
            Button("Move to Trash", role: .destructive) { model.confirmDeletion() }
            Button("Cancel", role: .cancel) { model.pendingDeletion = nil }
        } message: {
            if let pending = model.pendingDeletion {
                Text(
                    "\(pending.name) — \(pending.size.formattedBytes)\n\(pending.path)\n\n"
                        + "It goes to the Trash, so you can put it back with ⌘Z or from Finder.")
            }
        }
        // Reversible, unlike the empty below, so the wording leans on that: the reason to stop
        // and ask is the number of folders going at once, not the risk of losing them.
        .confirmationDialog(
            "Move these to the Trash?",
            isPresented: .init(
                get: { model.pendingClusterTrash != nil },
                set: { if !$0 { model.pendingClusterTrash = nil } })
        ) {
            Button("Move to Trash", role: .destructive) { model.confirmClusterTrash() }
            Button("Cancel", role: .cancel) { model.pendingClusterTrash = nil }
        } message: {
            if let pending = model.pendingClusterTrash {
                Text(
                    "\(pending.items.count) × \(pending.family.plural), "
                        + "\(pending.totalSize.formattedBytes) in total.\n\n"
                        + "\(pending.detail)\n\nThey go to the Trash, so ⌘Z puts them all back.")
            }
        }
        // Separate from the dialog above because the promise is the opposite one. Everything
        // else in Disker goes to the Trash and comes back with ⌘Z; this is the one action
        // that cannot, so it says so instead of borrowing the reassuring wording.
        .confirmationDialog(
            "Empty the Trash?",
            isPresented: .init(
                get: { model.pendingTrashEmpty != nil },
                set: { if !$0 { model.pendingTrashEmpty = nil } })
        ) {
            Button("Empty the Trash", role: .destructive) { model.confirmEmptyTrash() }
            Button("Cancel", role: .cancel) { model.pendingTrashEmpty = nil }
        } message: {
            if let pending = model.pendingTrashEmpty {
                Text(
                    "\(pending.size.formattedBytes) in \(pending.path)\n\n"
                        + "These items are deleted permanently. This cannot be undone.")
            }
        }
    }

    private var subtitle: String {
        switch model.scanState {
        case .loaded(let result):
            // A background re-walk after a deletion. The figures on screen are already right
            // about what was deleted, so this is a footnote rather than a spinner.
            if model.isReconciling {
                return "\(result.root.size.formattedBytes) · updating…"
            }
            // Say when the figure is stale rather than presenting cached numbers as live.
            if let cachedAt = model.cachedAt {
                let age = RelativeDateTimeFormatter()
                age.unitsStyle = .abbreviated
                return "\(result.root.size.formattedBytes) · scanned \(age.localizedString(for: cachedAt, relativeTo: Date()))"
            }
            return "\(result.root.size.formattedBytes) analyzed"
        case .scanning(let progress):
            return progress.map { "\($0.filesScanned.formatted()) files…" } ?? "Scanning…"
        case .failed: return "Scan failed"
        case .idle: return ""
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            // `NavigationSplitView` supplied this for free; an AppKit split view does not.
            Button {
                NSSplitViewController.toggleSidebarFromToolbar()
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.leading")
            }
            // The shortcut lives on the View menu item, not here — declaring it twice makes
            // neither reliable.
            .help("Show or hide the sidebar (⌃⌘S)")
            .accessibilityLabel("Show or hide the sidebar")
        }

        ToolbarItem(placement: .navigation) {
            // The disk picker from the design mock. Always present, even with one disk:
            // it names what you are looking at, which the window title alone stops doing
            // as soon as an external drive is plugged in.
            Menu {
                ForEach(model.availableVolumes) { volume in
                    Button {
                        Task { await model.select(volume) }
                    } label: {
                        Label(
                            "\(volume.name) — \(volume.totalCapacity.formattedBytes)",
                            systemImage: volume.symbolName)
                    }
                }
                if model.availableVolumes.isEmpty {
                    Text("No volumes found").foregroundStyle(.secondary)
                }
                Divider()
                Button("Refresh Disks") { model.refreshVolumes() }
            } label: {
                Label(
                    model.selectedVolume?.name ?? "Disk",
                    systemImage: model.selectedVolume?.symbolName ?? "internaldrive")
            }
            .menuIndicator(.visible)
            .accessibilityLabel("Choose which disk to analyze")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task {
                    await model.scan()
                    await model.loadMoleReport()
                }
            } label: {
                Label("Re-scan", systemImage: "arrow.clockwise")
            }
            .accessibilityLabel("Re-scan this volume")
            .disabled(isScanning)
        }

        // Separates the inspector toggle into its own glass capsule. It acts on the window's
        // chrome rather than on the data, so grouping it with Re-scan would read as one
        // control. Dropping the whole item — rather than filling it with an EmptyView —
        // is what keeps an empty capsule from being left behind in the sections that have
        // no inspector.
        if model.sectionSupportsInspector {
            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        model.showsInspector.toggle()
                    }
                } label: {
                    Label(
                        model.showsInspector ? "Hide Details" : "Show Details",
                        systemImage: "sidebar.right")
                }
                .help("Show or hide the details panel (⌃⌘I)")
                .accessibilityLabel(
                    model.showsInspector ? "Hide details panel" : "Show details panel")
            }
        }
    }

    private var isScanning: Bool {
        if case .scanning = model.scanState { return true }
        return false
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var appearance: AppearanceController

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                Text("The app icon follows the same setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Disk") {
                LabeledContent("Analyzing", value: model.selectedVolume?.name ?? "—")
                LabeledContent("Path", value: model.scanRoot)
                Text(
                    "Disker analyzes the data volume. The sealed system volume is a separate "
                        + "~12 GB of macOS that cannot be modified or reclaimed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 380)
    }
}
