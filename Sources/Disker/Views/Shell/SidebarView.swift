import DiskerCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.section) {
                Section {
                    ForEach(AppModel.Section.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbolName)
                            .tag(item)
                            .badge(
                                item == .recommendations && model.reclaimableSafely > 0
                                    ? model.reclaimableSafely.formattedBytes : nil)
                    }
                }

                Section("Locations") {
                    ForEach(topLevelLocations, id: \.name) { location in
                        HStack {
                            Label(location.name, systemImage: location.symbol)
                            Spacer()
                            Text(location.size.formattedBytes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            FreeSpaceCard(volume: model.volume)
                .padding(12)
        }
    }

    private struct Location {
        let name: String
        let symbol: String
        let size: UInt64
    }

    /// The largest children of the scan root, which is what the mock's "Locations" list shows.
    private var topLevelLocations: [Location] {
        guard case .loaded(let result) = model.scanState else { return [] }
        return result.root.children.prefix(6).map { node in
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
