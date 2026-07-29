import DiskerCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    /// Rows are buttons rather than `List` selection.
    ///
    /// Tag-based selection did not drive navigation here — clicks landed on the row and the
    /// detail view never changed, which is exactly the "they do nothing but show a size"
    /// symptom. Rather than keep guessing at why SwiftUI declined to write the binding back,
    /// each row now sets the section directly. Behaviour is explicit and the highlight is
    /// drawn to match a standard source list.
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(AppModel.Section.fixed) { item in
                        SidebarRow(
                            title: item.title,
                            symbol: item.symbolName,
                            trailing: badge(for: item),
                            isSelected: model.section == item
                        ) {
                            model.section = item
                        }
                    }

                    Text("Locations")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 3)

                    ForEach(topLevelLocations, id: \.name) { location in
                        let section = AppModel.Section.location(location.name)
                        SidebarRow(
                            title: location.name,
                            symbol: location.symbol,
                            trailing: location.size.formattedBytes,
                            isSelected: model.section == section
                        ) {
                            model.section = section
                            model.openLocation(named: location.name)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .scrollContentBackground(.hidden)

            FreeSpaceCard(volume: model.volume)
                .padding(12)
        }
    }

    /// One source-list row: icon, title, optional trailing value, selection highlight.
    private struct SidebarRow: View {
        let title: String
        let symbol: String
        let trailing: String?
        let isSelected: Bool
        let action: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .frame(width: 18)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    Text(title)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    Spacer(minLength: 6)
                    if let trailing {
                        Text(trailing)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(
                                isSelected
                                    ? AnyShapeStyle(.white.opacity(0.85))
                                    : AnyShapeStyle(.secondary))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(background)
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        }

        private var background: AnyShapeStyle {
            if isSelected { return AnyShapeStyle(.tint) }
            if isHovered { return AnyShapeStyle(.quaternary) }
            return AnyShapeStyle(.clear)
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
        .padding(12)
        .glassPanel()
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
