import DiskerCore
import SwiftUI

/// Mole as a section of its own.
///
/// The preview that powers this runs automatically in the background at launch, so opening
/// this view shows results rather than starting work. The button here is for configuring and
/// running an actual operation.
struct MoleView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summary
                if let report = model.moleReport {
                    switch report {
                    case .parsed(let categories, _):
                        categoryList(categories)
                    case .unparseable(let reason):
                        unparseable(reason)
                    }
                } else if model.isLoadingMole {
                    loading
                }
            }
            .padding(18)
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Mole")
                    .font(.title2.weight(.semibold))
                if let total = model.moleReport?.totalReclaimable, total > 0 {
                    Text("\(total.formattedBytes) can be cleaned")
                        .font(.headline)
                        .foregroundStyle(.tint)
                }
                Text(
                    "These figures come from a preview Disker runs in the background. "
                        + "Nothing has been deleted."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(spacing: 8) {
                Button {
                    model.launchMoleCleanup()
                } label: {
                    Label("Configure & Run…", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button {
                    Task { await model.loadMoleReport() }
                } label: {
                    Label("Refresh Preview", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(model.isLoadingMole)
            }
            .frame(width: 190)
        }
    }

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Asking Mole what it would remove…")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    private func categoryList(_ categories: [MoleCategory]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(categories.sorted { $0.totalSize > $1.totalSize }) { category in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(category.name).font(.headline)
                        Spacer()
                        Text(category.totalSize.formattedBytes)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ForEach(category.items) { item in
                        HStack {
                            Text(item.name)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(item.size.formattedBytes)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(12)
                .glassPanel(cornerRadius: 11)
            }
        }
    }

    private func unparseable(_ reason: String) -> some View {
        // Deliberately shows no number. A wrong reclaimable figure precedes a destructive
        // decision, so "couldn't read it" is the only honest output here.
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn't read Mole's output", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Mole Anyway") { model.launchMoleCleanup() }
                .buttonStyle(.glass)
        }
        .padding(14)
        .glassPanel(cornerRadius: 11)
    }
}
