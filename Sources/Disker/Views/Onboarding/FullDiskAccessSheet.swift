import DiskerCore
import SwiftUI

/// Explains why the numbers are short, and how to fix it.
///
/// Shown because the failure is otherwise invisible: macOS gives a non-sandboxed app no
/// prompt when it is denied, so the scan appears to succeed and simply under-reports.
struct FullDiskAccessSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var unreadableCount: Int {
        if case .loaded(let result) = model.scanState { return result.inaccessibleCount }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Some folders couldn't be read")
                        .font(.title3.weight(.semibold))
                    Text("\(unreadableCount.formatted()) folders were skipped")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text(
                "macOS protects folders like Mail, Messages, and Photos. Without Full Disk "
                    + "Access, Disker can't measure them — so the total it shows is lower than "
                    + "what's really on your disk."
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    stepRow(1, "Open Privacy & Security → Full Disk Access")
                    stepRow(2, "Turn on Disker in the list")
                    stepRow(3, "Quit and reopen Disker, then re-scan")
                }
                .padding(6)
            }

            // Worth stating plainly: without a stable signing identity the grant silently
            // disappears on the next build, and the user is left thinking they mis-clicked.
            Label(
                "If you rebuild Disker, macOS treats it as a new app and turns this off again. "
                    + "Running Tools/create-signing-identity.sh once prevents that.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Continue Anyway") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open Settings") {
                    model.openFullDiskAccessSettings()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tint)
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
    }
}
