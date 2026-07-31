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
///
/// These tests are deliberately synchronous. `pthread_sigmask` applies to the calling thread
/// only, so both the mask change and the fork have to happen on the same one — an `async` test
/// can hop threads at any suspension point, which made an earlier version of this suite both
/// flaky and not actually exercising the mask.
@Suite("Pseudo-terminal")
struct PseudoTerminalTests {

    /// Runs a shell command and waits until its output satisfies `until`, or the timeout.
    ///
    /// Waiting for the process to exit instead would race: the child is reaped on one queue
    /// while the pty is still being drained on another, so the transcript can still be empty
    /// when the exit callback lands.
    private func run(
        _ script: String,
        until satisfied: (String) -> Bool,
        timeout: TimeInterval = 20
    ) -> String {
        let collected = Collected()
        let terminal = PseudoTerminal(
            onOutput: { collected.append($0) },
            onStateChange: { _ in })

        // Called inline rather than dispatched, so the child inherits this thread's mask.
        terminal.start(
            executable: "/bin/sh", arguments: ["-c", script], columns: 80, rows: 24)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !satisfied(collected.text) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        terminal.terminate()
        return collected.text
    }

    /// A shell that inherits SIGTERM as SIG_IGN silently refuses to trap it, so signalling
    /// itself does nothing and only READY is printed. With the disposition reset the trap
    /// installs and fires, so CAUGHT appears too.
    private static let trapProbe = "trap 'echo CAUGHT' TERM; kill -TERM $$; sleep 1; echo READY"

    @Test("The child does not inherit an ignored SIGTERM")
    func childGetsDefaultSignalDispositions() {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }

        let output = run(Self.trapProbe, until: { $0.contains("READY") })

        #expect(output.contains("CAUGHT"))
        #expect(output.contains("READY"))
    }

    @Test("The child does not inherit a blocked signal mask")
    func childGetsAnEmptySignalMask() {
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTERM)
        pthread_sigmask(SIG_BLOCK, &blocked, nil)
        defer { pthread_sigmask(SIG_UNBLOCK, &blocked, nil) }

        // A blocked signal is inherited across exec too, and would defer the trap indefinitely.
        let output = run(Self.trapProbe, until: { $0.contains("READY") })

        #expect(output.contains("CAUGHT"))
    }

    @Test("Output reaches the callback")
    func streamsOutput() {
        let output = run("echo hello-from-pty", until: { $0.contains("hello-from-pty") })
        #expect(output.contains("hello-from-pty"))
    }
}

/// Collects callback output from the terminal's background queues.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
