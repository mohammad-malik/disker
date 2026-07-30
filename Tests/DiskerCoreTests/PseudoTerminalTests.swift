import Darwin
import Foundation
import Testing

@testable import DiskerCore

/// Guards the signal environment handed to the child.
///
/// launchd starts GUI applications with SIGTERM set to SIG_IGN, and an *ignored* disposition —
/// unlike an installed handler, which exec resets — survives execve. Passing it on made
/// `mole clean` stall for five minutes right after its "Cloud & Office" section: Mole wraps
/// that pass in a shell timeout, kills the `sleep` watchdog with SIGTERM when the work
/// finishes, then waits on it. With the kill ignored the wait ran the full 300 seconds and the
/// window looked frozen. Measured through this class: 375s with the ignore, 70-87s without.
@Suite("Pseudo-terminal")
struct PseudoTerminalTests {

    /// Runs a command to completion and returns everything it printed.
    private func run(_ arguments: [String], timeout: TimeInterval = 20) async -> String {
        let collected = Collected()
        let terminal = PseudoTerminal(
            onOutput: { data in collected.append(data) },
            onStateChange: { state in
                if case .finished = state { collected.finish() }
                if case .failed = state { collected.finish() }
            })

        Task.detached {
            terminal.start(
                executable: "/bin/sh", arguments: arguments, columns: 80, rows: 24)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !collected.isFinished && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        terminal.terminate()
        return collected.text
    }

    @Test("The child does not inherit an ignored SIGTERM")
    func childGetsDefaultSignalDispositions() async {
        // Stand in for launchd: ignore SIGTERM in this process before forking.
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }

        // A shell that inherits SIG_IGN silently refuses to trap the signal, so `kill` on
        // itself does nothing and only ALIVE is printed. With the disposition reset the trap
        // installs and fires, so CAUGHT appears first.
        let output = await run(["-c", "trap 'echo CAUGHT' TERM; kill -TERM $$; echo ALIVE"])

        #expect(output.contains("CAUGHT"))
        #expect(output.contains("ALIVE"))
    }

    @Test("The child does not inherit a blocked signal mask")
    func childGetsAnEmptySignalMask() async {
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTERM)
        pthread_sigmask(SIG_BLOCK, &blocked, nil)
        defer { pthread_sigmask(SIG_UNBLOCK, &blocked, nil) }

        // A blocked signal is inherited across exec too, and would defer the trap indefinitely.
        let output = await run(["-c", "trap 'echo CAUGHT' TERM; kill -TERM $$; sleep 1; echo ALIVE"])

        #expect(output.contains("CAUGHT"))
    }

    @Test("Output reaches the callback")
    func streamsOutput() async {
        let output = await run(["-c", "echo hello-from-pty"])
        #expect(output.contains("hello-from-pty"))
    }
}

/// Collects callback output from the terminal's background queues.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
