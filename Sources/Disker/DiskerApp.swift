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
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// Shared by every glass shape floating over the chart, so they can morph into one
    /// another as the breadcrumb grows and shrinks.
    @Namespace private var glassNamespace

    var body: some View {
        // No window background, no container background, no hidden toolbar background.
        // Liquid Glass is drawn by the system chrome — the toolbar, the inset sidebar, the
        // inspector — and every custom background previously installed here was painting
        // over the material rather than giving it something to refract.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        // Deliberately no window-level backdrop and no `isOpaque = false`.
        //
        // Four approaches at behind-window translucency were tried and none reached the
        // screen: clearing `NSWindow.backgroundColor`, a `.behindWindow` `NSVisualEffectView`
        // installed through `containerBackground(for: .window)`, hiding the sidebar list's
        // scroll background so that backdrop could show through, and a SwiftUI
        // `.ultraThinMaterial` as the window's container background. `NavigationSplitView`
        // paints opaque column backgrounds above all of them, and SwiftUI exposes no way to
        // opt out — the same wall the previous author hit and documented.
        //
        // Getting the desktop to show through the sidebar means an `NSSplitViewController`
        // with an `NSVisualEffectView` behind it, which is a shell rewrite rather than a
        // theming change. Until that is a deliberate decision, this stays opaque and the
        // glass does its work against the app's own content.
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
    }

    private var subtitle: String {
        switch model.scanState {
        case .loaded(let result):
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

    /// Whether the current section has anything for the inspector to describe.
    private var sectionSupportsInspector: Bool {
        switch model.section {
        case .overview, .location: return true
        case .recommendations, .mole: return false
        }
    }

    /// Keeps the user's preference in `showsInspector` while suppressing the panel in the
    /// sections that have nothing to put in it.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { model.showsInspector && sectionSupportsInspector },
            set: { model.showsInspector = $0 })
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch model.section {
            case .overview, .location:
                chart
            case .recommendations:
                RecommendationsPanel(model: model)
            case .mole:
                MoleView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The content layer is opaque even though the window is not. Figures over a chart
        // have to stay readable regardless of what is behind the window, and Apple's split
        // is exactly this: standard materials for content, Liquid Glass for the chrome
        // floating above it.
        .background(.background)
        // Transient, and above the content rather than part of it — so this is one of the
        // few things that stays glass.
        .overlay(alignment: .top) {
            if let error = model.lastError {
                errorBanner(error)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: model.lastError)
        // The system's inspector, not a hand-rolled panel: it comes with edge-to-edge
        // Liquid Glass, its own resizing, and the standard column behaviour.
        .inspector(isPresented: inspectorPresented) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .sheet(isPresented: $model.showingAccessSheet) {
            FullDiskAccessSheet(model: model)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { model.lastError = nil }
                .buttonStyle(.borderless)
        }
        .padding(12)
        .floatingGlass(in: .rect(cornerRadius: 14))
    }

    /// The chart, and the handful of controls that float above it.
    ///
    /// This is the app's one legitimate use of custom Liquid Glass: a rich canvas with
    /// controls over it. They share a single `GlassEffectContainer` so they render in one
    /// sampling pass — glass cannot sample other glass — and so a hover on one carries its
    /// illumination to the others. The spacing stays well under the real separation between
    /// the three groups; larger, and they would blend into one shape at rest.
    private var chart: some View {
        GlassEffectContainer(spacing: 12) {
            chartContent
                .overlay(alignment: .topLeading) {
                    // Empty on a first-run scan, and an empty row of capsules is just a
                    // glass artefact floating over a spinner.
                    if !model.breadcrumb.isEmpty {
                        BreadcrumbBar(model: model, namespace: glassNamespace)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 12) {
                        // The legend belongs with the floating controls rather than in the
                        // content: laid out below the chart it forced the chart to shrink,
                        // which opened the dead band the bars were floating over.
                        if model.currentRoot != nil {
                            CategoryLegend(
                                root: model.currentRoot,
                                rootComponents: model.rootComponents
                            )
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .floatingGlass(in: Capsule())
                        }
                        // Only on the chart: the other sections already show this in full,
                        // and repeating it below them is noise.
                        if case .overview = model.section {
                            RecommendationBar(model: model)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
        }
    }

    @ViewBuilder
    private var chartContent: some View {
        switch model.scanState {
        case .scanning(let progress):
            scanningState(progress)
        case .failed(let message):
            ContentUnavailableView(
                "Scan failed", systemImage: "exclamationmark.triangle",
                description: Text(message))
        case .loaded, .idle:
            // Full bleed. The previous version reserved space above and below for the
            // floating controls, which meant the chart never actually passed beneath them —
            // so the glass had a flat pane to lens and looked like a dark card. Content
            // running under the material is the entire effect.
            // Enough inset to keep the chart off the pane edges, not so much that it stops
            // reaching under the floating controls.
            SunburstView(model: model, namespace: glassNamespace)
                .padding(26)
        }
    }

    private func scanningState(_ progress: ScanProgress?) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(progress.map { "\($0.filesScanned.formatted()) files" } ?? "Starting…")
                .font(.headline)
            if let progress {
                Text(progress.currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
        if sectionSupportsInspector {
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
