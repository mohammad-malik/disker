import DiskerCore
import SwiftUI

/// Configure a Mole run, then watch it.
///
/// The previous version opened straight into a dry run with no choices. Mole exposes five
/// distinct operations and several options each, and a preview already runs in the
/// background to power the recommendations — so what this screen is actually for is deciding
/// what to run and whether it is for real.
struct MoleCleanupSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Shows the terminal when a run exists, otherwise the configuration form. Reopening
    /// after "Close (keeps running)" therefore returns to the run in progress.
    @State private var showingTerminal = false
    @State private var confirmingDestructive = false

    private var session: MoleSession { model.moleSession }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if showingTerminal {
                terminal
            } else {
                configuration
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 880, height: 660)
        // Only the terminal is pinned dark. The configuration form is ordinary app UI and
        // should follow the chosen appearance like everything else.
        .background(showingTerminal ? Color(white: 0.06) : Color.clear)
        .modifier(DarkWhenTerminal(active: showingTerminal))
        .onAppear { showingTerminal = session.hasOutput }
        .confirmationDialog(
            "Run for real?", isPresented: $confirmingDestructive
        ) {
            Button("Run \(model.moleConfiguration.operation.title)", role: .destructive) {
                start()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will delete files. Mole still asks before each step, and unless you "
                    + "chose Permanent, removed items go to the Trash.\n\n"
                    + model.moleConfiguration.commandLine())
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(
                systemName: showingTerminal
                    ? (session.configuration?.operation.symbolName ?? "terminal")
                    : "slider.horizontal.3"
            )
            .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle).font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            if session.isRunning {
                Button("Stop") { session.interrupt() }
                    .help("Sends Ctrl-C to Mole and its helpers")
            }
            if showingTerminal, !session.isRunning {
                Button {
                    showingTerminal = false
                } label: {
                    Label("New Run", systemImage: "chevron.backward")
                }
                .help("Back to the options")
            }
        }
        .padding(12)
    }

    private var headerTitle: String {
        guard showingTerminal else { return "Optimize with Mole" }
        let operation = session.configuration?.operation.title ?? "Mole"
        return session.configuration?.dryRun == true ? "\(operation) — Preview" : operation
    }

    private var statusText: String {
        guard showingTerminal else {
            return "Choose what Mole should do. Preview first if you're unsure."
        }
        switch session.state {
        case .idle: return "Ready"
        case .running:
            return session.configuration?.dryRun == true
                ? "Previewing — nothing will be deleted"
                : "Answer Mole's prompts below. Type your password if it asks for sudo."
        case .finished(let code):
            return code == 0 ? "Finished" : "Exited with code \(code)"
        case .failed(let message): return message
        }
    }

    // MARK: - Configuration

    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                operationPicker
                Divider()
                options
                Divider()
                commandPreview
            }
            .padding(18)
        }
    }

    private var operationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Operation").font(.subheadline.weight(.semibold))
            ForEach(MoleOperation.allCases) { operation in
                Button {
                    model.moleConfiguration.operation = operation
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: operation.symbolName)
                            .frame(width: 22)
                            .foregroundStyle(
                                model.moleConfiguration.operation == operation
                                    ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(operation.title).font(.callout.weight(.medium))
                            Text(operation.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if model.moleConfiguration.operation == operation {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(
                                model.moleConfiguration.operation == operation
                                    ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var options: some View {
        let operation = model.moleConfiguration.operation

        VStack(alignment: .leading, spacing: 12) {
            Text("Options").font(.subheadline.weight(.semibold))

            Toggle(isOn: $model.moleConfiguration.dryRun) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Preview only (dry run)")
                    Text("Shows what would be removed without touching anything.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if operation.supportsIncludeEmpty {
                Toggle(isOn: $model.moleConfiguration.includeEmpty) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Include empty artifact folders")
                        Text("Also lists zero-size build directories.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if operation.supportsCustomPaths {
                // Mole stores its own scan paths; editing them is its own interactive screen,
                // so Disker sends the user there rather than duplicating the list.
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Project folders")
                        Text("Mole scans its configured project directories.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit in Mole…") { model.runMoleSettings(argument: "--paths") }
                }
            }

            if operation.supportsWhitelist {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Protected items")
                        Text("Paths Mole will never touch.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Manage whitelist…") { model.runMoleSettings(argument: "--whitelist") }
                }
            }

            if operation.supportsExternalVolume {
                VStack(alignment: .leading, spacing: 4) {
                    Text("External volume (optional)")
                    HStack {
                        TextField(
                            "/Volumes/MyDrive", text: $model.moleConfiguration.externalVolumePath
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("Choose…") { model.chooseExternalVolume() }
                    }
                    Text("Removes macOS metadata from a mounted external drive.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if operation.supportsAppNames {
                VStack(alignment: .leading, spacing: 4) {
                    Text("App names (optional)")
                    TextField("slack zoom", text: $model.moleConfiguration.appNames)
                        .textFieldStyle(.roundedBorder)
                    Text("Leave empty to pick from Mole's interactive list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if operation.supportsPermanent {
                Toggle(isOn: $model.moleConfiguration.permanent) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Delete permanently")
                        // Named plainly: this is the one option with no way back.
                        Text("Bypasses the Trash — removed files cannot be recovered.")
                            .font(.caption)
                            .foregroundStyle(model.moleConfiguration.permanent ? .red : .secondary)
                    }
                }
            }

            if operation.mayRequireSudo, !model.moleConfiguration.dryRun {
                Label(
                    "Mole will ask for your password to reach system caches. Type it into the "
                        + "terminal when prompted.",
                    systemImage: "lock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var commandPreview: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Command").font(.subheadline.weight(.semibold))
            Text(model.moleConfiguration.commandLine())
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
            Text("Exactly what Disker will run.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Terminal

    private var terminal: some View {
        ScrollView([.vertical, .horizontal]) {
            TerminalScreenView(cells: session.cells, fontSize: 11.5)
                .padding(10)
        }
        .background(.black.opacity(0.5))
        .overlay {
            TerminalKeyCatcher { session.send($0) }
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !showingTerminal {
                Button {
                    if model.moleConfiguration.isDestructive {
                        confirmingDestructive = true
                    } else {
                        start()
                    }
                } label: {
                    Label(
                        model.moleConfiguration.dryRun ? "Preview" : "Run",
                        systemImage: model.moleConfiguration.dryRun ? "eye" : "play.fill")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                if case .finished = session.state, session.configuration?.dryRun == true {
                    // The natural next step after a preview, without retyping the options.
                    Button {
                        model.moleConfiguration.dryRun = false
                        confirmingDestructive = true
                    } label: {
                        Label("Run This For Real", systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                }
                if case .finished = session.state, session.configuration?.dryRun == false {
                    Button("Re-scan Disk") {
                        dismiss()
                        Task { await model.scan() }
                    }
                    .buttonStyle(.glassProminent)
                }
            }

            Spacer()

            if showingTerminal, !session.isRunning {
                Button("Clear") { session.reset(); showingTerminal = false }
            }

            Button(session.isRunning ? "Close (keeps running)" : "Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private func start() {
        session.run(model.moleConfiguration)
        showingTerminal = true
    }
}

/// Forces the dark appearance only while the terminal is on screen. A terminal stays dark in
/// both themes, so its surrounding labels need the dark-appearance variants or they turn
/// black-on-black when the app is set to light.
private struct DarkWhenTerminal: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.environment(\.colorScheme, .dark)
        } else {
            content
        }
    }
}
