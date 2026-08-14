import DiskerCore
import SwiftUI

/// The window's content column.
///
/// Split out of `ContentView` so an `NSHostingController` can own it — see `SplitShell` for
/// why the shell around it is AppKit.
///
/// This is the content layer, and it is deliberately opaque even though the window is not.
/// Figures over a chart have to stay readable regardless of what is behind the window, which
/// is exactly Apple's split: standard materials for content, Liquid Glass for the chrome
/// floating above it.
struct DetailView: View {
    @Bindable var model: AppModel

    /// Shared by every glass shape floating over the chart, so they can morph into one
    /// another as the breadcrumb grows and shrinks.
    @Namespace private var glassNamespace

    var body: some View {
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

    /// Keeps the user's preference in `showsInspector` while suppressing the panel in the
    /// sections that have nothing to put in it.
    ///
    /// The setter has to ignore writes from the suppressed sections. The getter reports
    /// `false` there regardless of the preference, and SwiftUI writes that observed value
    /// back through the binding — which used to overwrite `showsInspector` with `false`.
    /// Visiting Recommendations and returning to the chart silently lost a panel the user
    /// had open, with no way to tell what had turned it off.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { model.showsInspector && model.sectionSupportsInspector },
            set: { newValue in
                guard model.sectionSupportsInspector else { return }
                model.showsInspector = newValue
            })
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
                // Top-trailing, not over the middle of the chart. The chart is a circle in a
                // wide pane, so this corner is dead space — where the legend sat before it
                // covered live wedges for no reason, and glass over saturated colour turns
                // muddy rather than lensing anything useful.
                .overlay(alignment: .topTrailing) {
                    if model.currentRoot != nil {
                        CategoryLegend(
                            root: model.currentRoot,
                            rootComponents: model.rootComponents
                        )
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .floatingGlass(in: Capsule())
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }
                }
                .overlay(alignment: .bottom) {
                    // Only on the chart: the other sections already show this in full,
                    // and repeating it below them is noise.
                    if case .overview = model.section {
                        RecommendationBar(model: model)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                    }
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
            // Full bleed. An earlier version reserved space above and below for the floating
            // controls, which meant the chart never actually passed beneath them — so the
            // glass had a flat pane to lens and looked like a dark card. Content running
            // under the material is the entire effect. Enough inset to keep the chart off
            // the pane edges, not so much that it stops reaching under the controls.
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
}
