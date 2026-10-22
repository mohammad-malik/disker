import DiskerCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// A standard source list.
    ///
    /// This was previously a `ScrollView` of custom buttons, because tag-based selection
    /// "did not drive navigation" — but the missing piece was never the binding. Selecting a
    /// location sets the section without telling the model which folder to open, so the
    /// detail pane kept showing the previous one; the buttons had been calling
    /// `openLocation` by hand. The proxy binding below restores that side effect, which lets
    /// this go back to a real `List` — and a real `List` is what picks up Tahoe's inset
    /// floating glass sidebar and its selection material. Nothing here paints a background:
    /// a custom fill in a sidebar blocks that glass outright.
    /// Radius of the selection highlight, chosen to match the corner of the sidebar panel
    /// it sits inside. The system's own sidebar selection is noticeably rounder than that
    /// panel, which is why the highlight is drawn here rather than left to `List`.
    private static let selectionRadius: CGFloat = 10

    var body: some View {
        // Rows are buttons and the highlight is drawn here, rather than using
        // `List(selection:)`.
        //
        // Two reasons, and the first is behavioural. Drilling into the chart moves the view
        // without changing `section`, so a few levels deep the current location is still the
        // selected row — and clicking it is the obvious way back to the top of that folder.
        // A selection binding only fires when the value *changes*, so that click never
        // reached the model and the row was simply dead. A `simultaneousGesture` does not
        // help either; the list consumes the click first.
        //
        // The second is that the system's selection shape is much rounder than the panel it
        // sits in, and its radius is not adjustable. This is how the sidebar worked before
        // it moved to `List`, so keyboard selection is no worse than it was.
        List {
            Section {
                ForEach(AppModel.Section.fixed) { item in
                    sidebarRow(
                        section: item, title: item.title, symbol: item.symbolName,
                        trailing: badge(for: item)
                    ) {
                        model.section = item
                    }
                }
                debloatRow
            }

            Section("Locations") {
                ForEach(topLevelLocations, id: \.name) { location in
                    let section = AppModel.Section.location(location.name)
                    sidebarRow(
                        section: section, title: location.name, symbol: location.symbol,
                        trailing: location.size.formattedBytes
                    ) {
                        model.section = section
                        model.openLocation(named: location.name)
                    }
                }
            }
        }
        // The split view's sidebar item brings the vibrancy; the list must not paint over
        // it. This is the one background removal that matters — with the list drawing its
        // own, the desktop stops at the hosting view and the sidebar goes flat.
        .scrollContentBackground(.hidden)
        // The sidebar is an inset panel with rounded corners, and the first row was landing
        // about 2pt from its top edge against 10pt at the sides — close enough that the
        // selection highlight ran into the corner radius and read as spilling outside the
        // panel. This gives the top the same breathing room the sides already had.
        //
        // Padding rather than `contentMargins(.top:for: .scrollContent)`, which had no
        // effect here, or a `safeAreaInset`, which would only move the resting position and
        // let rows scroll into the corner anyway. Insetting the list itself keeps them out
        // of that band entirely, and the vibrancy behind still fills it.
        .padding(.top, 8)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let update = model.availableUpdate {
                    Divider()
                    UpdateCard(release: update)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }
                Divider()
                FreeSpaceCard(volume: model.volume)
                    .padding(12)
            }
        }
    }

    /// One source-list row: icon, title, optional size, and the selection highlight.
    private func sidebarRow(
        section: AppModel.Section,
        title: String,
        symbol: String,
        trailing: String?,
        action: @escaping () -> Void
    ) -> some View {
        let isSelected = model.section == section
        return Button(action: action) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(
                            isSelected
                                ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        // A truncated size is a wrong number, so this never shrinks. If the
                        // sidebar is dragged narrow enough, the title gives way instead.
                        .fixedSize()
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Self.selectionRadius, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
            )
            // Without this only the glyphs are clickable, not the whole row.
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Zero horizontal inset so the highlight spans the list's own content width; the
        // padding inside the background is what keeps the label off its edge. Insetting
        // here as well pushed the whole row visibly inward.
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
        .listRowSeparator(.hidden)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Opens RemoveMacAI's window rather than selecting a section, so it is never
    /// highlighted. It sits among the sections anyway, with the same size badge, because a
    /// menu item and a shortcut alone left the feature invisible: the sidebar is where every
    /// other way to get space back is found, and the model figure is the reason to click.
    private var debloatRow: some View {
        Button {
            openWindow(id: DebloatWindow.id)
        } label: {
            HStack(spacing: 6) {
                // Explicit, as in `sidebarRow`: a plain button's label is otherwise drawn in
                // the dimmed style that reads as disabled.
                Label("Debloat macOS", systemImage: "apple.intelligence")
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                if let bytes = model.appleIntelligenceBytes, bytes > 0 {
                    Text(bytes.formattedBytes)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
        .listRowSeparator(.hidden)
        .help("Turn off Apple Intelligence, analytics and other macOS extras, and delete the AI models")
        .accessibilityHint("Opens in a new window")
    }

    private func badge(for item: AppModel.Section) -> String? {
        switch item {
        case .recommendations:
            return model.reclaimableSafely > 0 ? model.reclaimableSafely.formattedBytes : nil
        case .mole:
            let total = model.moleReport?.totalReclaimable ?? 0
            return total > 0 ? total.formattedBytes : nil
        default:
            return nil
        }
    }

    private struct Location {
        let name: String
        let symbol: String
        let size: UInt64
    }

    private var topLevelLocations: [Location] {
        guard case .loaded(let result) = model.scanState else { return [] }
        return result.root.children
            .filter { $0.isDirectory }
            .prefix(8)
            .map { node in
                Location(name: node.name, symbol: symbol(for: node.name), size: node.size)
            }
    }

    private func symbol(for name: String) -> String {
        switch name {
        case "Users": return "person.2.fill"
        case "Applications": return "square.grid.2x2.fill"
        case "Library", "System": return "gearshape.fill"
        case "Documents": return "doc.fill"
        case "Downloads": return "arrow.down.circle.fill"
        case "opt", "usr", "bin", "sbin": return "terminal.fill"
        case "private", "var": return "lock.fill"
        default: return "folder.fill"
        }
    }
}

/// A newer Disker is out. In the sidebar rather than an alert: it is worth knowing, not
/// worth interrupting a scan for, and it stays put until the user acts on it.
struct UpdateCard: View {
    let release: AvailableRelease
    @Environment(\.openURL) private var openURL

    var body: some View {
        // Stacked rather than one row: at sidebar width a trailing button squeezed the title
        // into breaking mid-phrase.
        VStack(alignment: .leading, spacing: 6) {
            Label("Disker \(release.version) is available", systemImage: "arrow.down.circle.fill")
                .font(.subheadline.weight(.medium))
                .labelStyle(TintedIconLabelStyle())
            Text("Includes the latest Debloat fixes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Download") { openURL(release.url) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // No material, for the same reason as `FreeSpaceCard`: the sidebar is already glass.
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Download") { openURL(release.url) }
    }
}

/// An accent-coloured icon beside primary text.
private struct TintedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(.tint)
            configuration.title
        }
    }
}

struct FreeSpaceCard: View {
    let volume: VolumeInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Free Space")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let volume {
                    Text("\(Int((1 - volume.usedFraction) * 100))%")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { geometry in
                let fraction = volume?.usedFraction ?? 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: barColors(for: fraction),
                                startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 6)

            if let volume {
                Text(
                    "\(volume.availableCapacity.formattedBytes) free of \(volume.totalCapacity.formattedBytes)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                // Purgeable space is why "free" here can disagree with other tools. Naming it
                // is better than quietly showing a number the user cannot actually use.
                if volume.purgeableCapacity > 0 {
                    Text("\(volume.purgeableCapacity.formattedBytes) purgeable")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // No material. This sits inside the sidebar, which the system already renders in
        // Liquid Glass, and glass on glass is the one thing Apple rules out outright.
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    /// Shifts toward red as the disk fills — the bar should read as a warning before the
    /// user has to work out what the number means.
    private func barColors(for fraction: Double) -> [Color] {
        fraction > 0.9
            ? [.orange, .red]
            : [Color(red: 0.35, green: 0.6, blue: 0.98), Color(red: 0.55, green: 0.45, blue: 0.95)]
    }
}
