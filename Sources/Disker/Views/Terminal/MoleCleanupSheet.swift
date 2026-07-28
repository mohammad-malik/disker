import DiskerCore
import SwiftUI

/// Runs `mole clean` inside Disker.
///
/// Mole is interactive and needs sudo for system caches, so this is not a silent operation —
/// the user still reviews and confirms each step. The difference from the previous design is
/// that it happens here rather than in a Terminal window Disker asked the system to open,
/// which required Automation permission and silently did nothing without it.
@MainActor
@Observable
final class MoleSession {
    private(set) var cells: [[TerminalCell]] = []
    private(set) var state: PseudoTerminal.State = .idle

    private let emulator = TerminalEmulator(rows: 34, columns: 110)
    private var terminal: PseudoTerminal?
    private let client = MoleClient()

    var isRunning: Bool { state == .running }

    func start(dryRun: Bool) {
        guard let binary = client.locateBinary() else {
            state = .failed("Mole is not installed. Install it with: brew install mole")
            return
        }

        let terminal = PseudoTerminal(
            onOutput: { [weak self] data in
                Task { @MainActor in
                    guard let self else { return }
                    self.emulator.feed(data)
                    self.cells = self.emulator.snapshot()
                }
            },
            onStateChange: { [weak self] newState in
                Task { @MainActor in self?.state = newState }
            })

        self.terminal = terminal
        cells = emulator.snapshot()

        // forkpty blocks briefly; keep it off the main actor so the sheet appears instantly.
        Task.detached(priority: .userInitiated) {
            terminal.start(
                executable: binary,
                arguments: dryRun ? ["clean", "--dry-run"] : ["clean"],
                columns: 110, rows: 34)
        }
    }

    func send(_ text: String) {
        terminal?.send(text)
    }

    func interrupt() {
        terminal?.interrupt()
    }

    func stop() {
        terminal?.terminate()
        terminal = nil
    }
}

struct MoleCleanupSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var session = MoleSession()
    /// Starts in preview mode. The first thing shown should never be a live delete.
    @State private var dryRun = true
    @State private var hasStarted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            terminal
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 860, height: 620)
        .background(.black.opacity(0.86))
        .task {
            // Opens straight into a preview so the user sees what would be removed before
            // anything is. Guarded because .task re-runs on some view identity changes.
            guard !hasStarted else { return }
            hasStarted = true
            session.start(dryRun: true)
        }
        .onDisappear { session.stop() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.sparkles")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(dryRun ? "Mole — Preview" : "Mole — Cleanup")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.isRunning {
                Button("Stop") { session.interrupt() }
                    .help("Sends Ctrl-C to Mole")
            }
        }
        .padding(12)
    }

    private var statusText: String {
        switch session.state {
        case .idle: return "Ready"
        case .running:
            return dryRun
                ? "Previewing — nothing will be deleted"
                : "Answer Mole's prompts below. Type your password if it asks for sudo."
        case .finished(let code):
            return code == 0 ? "Finished" : "Exited with code \(code)"
        case .failed(let message): return message
        }
    }

    private var terminal: some View {
        ScrollView([.vertical, .horizontal]) {
            TerminalScreenView(cells: session.cells, fontSize: 11.5)
                .padding(10)
        }
        .background(.black.opacity(0.5))
        .overlay {
            // Invisible, but holds first responder so arrow keys and Ctrl-C reach Mole.
            TerminalKeyCatcher { session.send($0) }
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)
        }
    }

    private var footer: some View {
        HStack {
            if case .finished = session.state, dryRun {
                // Only offer the real run once a preview has actually been seen.
                Button {
                    dryRun = false
                    session.stop()
                    session = MoleSession()
                    session.start(dryRun: false)
                } label: {
                    Label("Run Cleanup for Real", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .help("Deletes the items listed above. Mole will ask before each step.")
            }

            Spacer()

            if case .finished = session.state, !dryRun {
                Button("Re-scan Disk") {
                    dismiss()
                    Task { await model.scan() }
                }
                .buttonStyle(.glassProminent)
                .help("Updates Disker's numbers to reflect what was freed")
            }

            Button(session.isRunning ? "Close (keeps running)" : "Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}
