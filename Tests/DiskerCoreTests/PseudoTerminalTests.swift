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
///
/// `.serialized` because these tests cannot correctly share a process. `signal(SIGTERM,
/// SIG_IGN)` sets a **process-wide** disposition, not a thread-local one, and swift-testing
/// runs tests in parallel by default — so one test's global mutation lands on another test's
/// forked child.
///
/// What was measured, since the mechanism deserves to be stated precisely rather than
/// guessed at:
///
/// - In parallel the suite failed intermittently — 10 runs in 20 on a busy machine, about 1
///   in 20 on an idle one. With `--no-parallel`, 0 in 20 under the same conditions. Each test
///   on its own, 20 in 20 clean. Serialized, 30 clean, plus 15 more under deliberate CPU load.
/// - A failing child died immediately after `fork`, before it had reset a single signal
///   disposition, with a wait status of 9 — killed by `SIGKILL` — and an empty transcript.
///   Every test in the suite then timed out together at 20 seconds.
/// - It was not memory pressure: no jetsam entries in the system log, 47% of memory free.
///
/// **What sends that SIGKILL was not identified**; narrowing it further needs `dtrace` and
/// root. The trait is justified regardless, because two tests mutating one process's signal
/// dispositions concurrently is invalid whatever the proximate cause. If this suite ever
/// needs to run in parallel again, that question has to be answered first.
///
/// Anything added here that forks, or touches process-wide signal state, must keep this trait.
@Suite("Pseudo-terminal", .serialized)
struct PseudoTerminalTests {

    /// Runs a shell command and waits until its output satisfies `until`, or the timeout.
    ///
    /// Waiting for the process to exit instead would race: the child is reaped on one queue
    /// while the pty is still being drained on another, so the transcript can still be empty
    /// when the exit callback lands.
    private func run(
        _ script: String,
        until satisfied: (String) -> Bool,
        environment: [String: String] = [:],
        timeout: TimeInterval = 20
    ) -> String {
        let collected = Collected()
        let terminal = PseudoTerminal(
            onOutput: { collected.append($0) },
            onStateChange: { _ in })

        // Called inline rather than dispatched, so the child inherits this thread's mask.
        terminal.start(
            executable: "/bin/sh", arguments: ["-c", script], environment: environment,
            columns: 80, rows: 24)

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

    /// argv and envp are built before the fork, because the child may not allocate. That
    /// hoisting is easy to get subtly wrong — a lost inherited variable, a dropped override,
    /// or a missing NULL terminator — and none of it would show up as a crash, only as Mole
    /// behaving oddly. So assert all three cases reach the child: inherited, overridden, and
    /// the TERM that makes Mole draw its interface at all.
    @Test("The child receives inherited, added, and overridden environment entries")
    func passesEnvironment() {
        setenv("DISKER_PTY_INHERITED", "from-parent", 1)
        defer { unsetenv("DISKER_PTY_INHERITED") }

        let output = run(
            "printf 'T=%s A=%s I=%s\\n' \"$TERM\" \"$DISKER_PTY_ADDED\" \"$DISKER_PTY_INHERITED\"",
            until: { $0.contains("I=") },
            environment: ["DISKER_PTY_ADDED": "from-caller"])

        #expect(output.contains("T=xterm-256color"))
        #expect(output.contains("A=from-caller"))
        #expect(output.contains("I=from-parent"))
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
