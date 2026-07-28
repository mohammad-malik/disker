import DiskerCore
import SwiftUI

@main
struct DiskerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1360, height: 880)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands { DiskerCommands(model: model) }

        Settings { SettingsView(model: model) }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                // The sidebar's own material would otherwise paint over the transparent
                // window and reintroduce the flat background glass needs to avoid.
                .toolbarBackground(.hidden, for: .windowToolbar)
        } detail: {
            detail
        }
        // Clear window + frosted backdrop, in that order. The clear window removes the
        // opaque slab that made glass render flat; the backdrop then gives it something
        // to refract, so panels read as material rather than as holes.
        .transparentWindowBackground(enabled: !reduceTransparency)
        // Must be `containerBackground`, not `.background`. NavigationSplitView draws its
        // own opaque sidebar and detail panes, which sit above any ordinary background
        // modifier and hid the backdrop entirely — the window stayed flat grey.
        // containerBackground installs beneath that chrome.
        // Must be `containerBackground`, not `.background`. NavigationSplitView draws its
        // own opaque panes above any ordinary background modifier, which hid this entirely.
        //
        // Neutral, uncoloured frost. An earlier version painted coloured light pools here to
        // guarantee the glass had something vivid to refract; it read as a rainbow gradient,
        // which is the opposite of what this material is. Glass should show what is actually
        // behind the window, even when that is something plain.
        //
        // Two extremes were wrong. `.underWindowBackground` frosted the whole window before
        // the panels could sample it, so they refracted a grey slab rather than the screen.
        // Fully clear went the other way: real refraction, but the desktop read straight
        // through the panels and the terminal behind became legible under the numbers.
        //
        // `.sidebar` is the middle — translucent enough that the glass has genuine depth to
        // lens, opaque enough that dense figures stay readable over whatever is behind.
        .containerBackground(for: .window) {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                VisualEffectBackdrop(material: .sidebar)
            }
        }
        .navigationTitle(model.volume?.name ?? "Disker")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .task {
            model.refreshVolume()
            // Show the previous scan instantly when there is one. Only walk the disk when
            // there is nothing to show — an empty window with a "Scan" button asks the user
            // to confirm the one thing they opened the app to do, but a three-minute spinner
            // over numbers that barely moved since yesterday is no better.
            if !model.loadCachedScan() {
                await model.scan()
            }
            await model.loadMoleReport()
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

    @ViewBuilder
    private var detail: some View {
        // GlassEffectContainer is what makes these panels behave as one material rather than
        // three independent blurs: it shares a single sampling pass, so nearby glass shapes
        // blend and their edges respond to each other instead of stacking into muddy grey.
        // Omitting it was why the panels read as flat cards.
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 14) {
                if let error = model.lastError {
                    errorBanner(error)
                }

                switch model.section {
                case .overview:
                    HStack(alignment: .top, spacing: 14) {
                        chartPanel
                        InspectorView(model: model)
                    }
                case .recommendations:
                    RecommendationsPanel(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .glassPanel()
                }

                RecommendationBar(model: model)
            }
        }
        .padding(14)
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
        .glassPanel(cornerRadius: 11)
    }

    @ViewBuilder
    private var chartPanel: some View {
        VStack(spacing: 10) {
            breadcrumb
            switch model.scanState {
            case .scanning(let progress):
                scanningState(progress)
            case .failed(let message):
                ContentUnavailableView(
                    "Scan failed", systemImage: "exclamationmark.triangle", description: Text(message))
            case .loaded, .idle:
                SunburstView(model: model)
                CategoryLegend(root: model.currentRoot)
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .glassPanel()
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

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(node.name) {
                    model.drillUp(to: index)
                }
                .buttonStyle(.plain)
                .font(index == model.breadcrumb.count - 1 ? .headline : .subheadline)
                .foregroundStyle(index == model.breadcrumb.count - 1 ? .primary : .secondary)
            }
            Spacer()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
    }

    private var isScanning: Bool {
        if case .scanning = model.scanState { return true }
        return false
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            LabeledContent("Scan root", value: model.scanRoot)
            Text(
                "Disker scans the data volume. The sealed system volume is a separate ~12 GB "
                    + "of macOS that cannot be modified or reclaimed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 160)
    }
}
