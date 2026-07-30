import DiskerCore
import SwiftUI

/// A Mole run and its terminal output.
///
/// Owned by `AppModel`, not by the sheet. Holding it in the sheet's `@State` meant closing
/// the window discarded the run — the button said "keeps running", and the process really
/// did keep running, but reopening built a fresh session and started over, so the output was
/// gone and a second copy launched.
@MainActor
@Observable
final class MoleSession {
    private(set) var cells: [[TerminalCell]] = []
    /// Bumped on every chunk of output.
    ///
    /// The view follows the tail on changes to this rather than to `cells.count`, which stops
    /// changing once scrollback reaches its cap even though output is still arriving — so
    /// following would quietly stop during exactly the long runs it exists for. It also misses
    /// progress lines that rewrite in place without adding a row.
    private(set) var revision = 0
    private(set) var state: PseudoTerminal.State = .idle
    /// What produced the output currently on screen.
    private(set) var configuration: MoleConfiguration?
    private(set) var startedAt: Date?

    private var emulator = TerminalEmulator(rows: 34, columns: 110)
    private var terminal: PseudoTerminal?
    private let client = MoleClient()

    var isRunning: Bool { state == .running }
    var hasOutput: Bool { configuration != nil }

    /// Whether a finished run can be re-shown rather than restarted.
    var canResume: Bool {
        if case .finished = state { return true }
        return isRunning
    }

    func run(_ configuration: MoleConfiguration) {
        launch(arguments: configuration.arguments(), configuration: configuration)
    }

    /// Runs an arbitrary Mole invocation — used for its own interactive editors such as
    /// `--whitelist` and `--paths`, which have no dry-run equivalent to model.
    func runRaw(arguments: [String], label: MoleOperation) {
        var configuration = MoleConfiguration()
        configuration.operation = label
        configuration.dryRun = false
        launch(arguments: arguments, configuration: configuration)
    }

    private func launch(arguments: [String], configuration: MoleConfiguration) {
        guard let binary = client.locateBinary() else {
            state = .failed("Mole is not installed. Install it with: brew install mole")
            return
        }

        // Replace any previous run cleanly rather than leaving an orphan attached to a pty
        // nothing is reading.
        terminal?.terminate()
        emulator = TerminalEmulator(rows: 34, columns: 110)
        cells = emulator.displayLines()
        self.configuration = configuration
        startedAt = Date()

        let terminal = PseudoTerminal(
            onOutput: { [weak self] data in
                Task { @MainActor in
                    guard let self else { return }
                    self.emulator.feed(data)
                    // Scrollback plus the live screen, so output longer than one screenful
                    // stays readable instead of scrolling into nothing.
                    self.cells = self.emulator.displayLines()
                    self.revision &+= 1
                }
            },
            onStateChange: { [weak self] newState in
                Task { @MainActor in self?.state = newState }
            })

        self.terminal = terminal

        // forkpty blocks briefly; keep it off the main actor so the sheet stays responsive.
        Task.detached(priority: .userInitiated) {
            terminal.start(
                executable: binary, arguments: arguments, columns: 110, rows: 34)
        }
    }

    func send(_ text: String) { terminal?.send(text) }

    /// Stops the run, escalating if Mole ignores the interrupt.
    func interrupt() {
        isStopping = true
        terminal?.stopEscalating { [weak self] _ in
            Task { @MainActor in self?.isStopping = false }
        }
    }

    /// True between pressing Stop and the process actually exiting, so the button can show
    /// that escalation is under way rather than looking inert.
    private(set) var isStopping = false

    /// Ends the run and clears the transcript.
    func reset() {
        terminal?.terminate()
        terminal = nil
        emulator = TerminalEmulator(rows: 34, columns: 110)
        cells = []
        state = .idle
        configuration = nil
        startedAt = nil
    }

    /// Stops the process but keeps the output visible, for when the app is quitting.
    func stopProcess() {
        terminal?.terminate()
        terminal = nil
    }
}
