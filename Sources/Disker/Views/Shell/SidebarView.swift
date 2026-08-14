import DiskerCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

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
    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(AppModel.Section.fixed) { item in
                    row(title: item.title, symbol: item.symbolName, trailing: badge(for: item))
                        .tag(item)
                }
            }

            Section("Locations") {
                ForEach(topLevelLocations, id: \.name) { location in
                    let section = AppModel.Section.location(location.name)
                    // A button, not a bare selectable row.
                    //
                    // Drilling into the chart moves the view without changing `section`, so
                    // a few levels deep this row is still the selected one — and clicking it
                    // is the obvious way back to the top of that folder. `List`'s selection
                    // binding only fires when the value *changes*, so that click never
                    // reached the model and the row was simply dead. A `simultaneousGesture`
                    // does not help either; the list consumes the click first. Handling it
                    // as a button means every click navigates, whether or not the selection
                    // moved. The binding still supplies the highlight through its getter.
                    Button {
                        model.section = section
                        model.openLocation(named: location.name)
                    } label: {
                        row(
                            title: location.name,
                            symbol: location.symbol,
                            trailing: location.size.formattedBytes
                        )
                        // Without this only the glyphs are clickable, not the whole row.
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .tag(section)
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
                Divider()
                FreeSpaceCard(volume: model.volume)
                    .padding(12)
            }
        }
    }

    /// Selection with the navigation side effect the section change alone does not perform.
    private var selection: Binding<AppModel.Section?> {
        Binding(
            get: { model.section },
            set: { newValue in
                // The equality check is defensive: `List` can hand back the current
                // selection during reconciliation, and re-running `openLocation` would
                // throw away the drill-down the user had navigated to.
                guard let newValue, newValue != model.section else { return }
                model.section = newValue
                if case .location(let name) = newValue {
                    model.openLocation(named: name)
                }
            })
    }

    /// One source-list row. Selection styling is the system's — a sidebar row that paints its
    /// own highlight cannot pick up the material behind it.
    private func row(title: String, symbol: String, trailing: String?) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // A truncated size is a wrong number, so this never shrinks. If the
                    // sidebar is dragged narrow enough, the title gives way instead.
                    .fixedSize()
            }
        }
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
