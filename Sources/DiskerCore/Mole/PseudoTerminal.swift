import Darwin
import Foundation

/// Runs a command attached to a pseudo-terminal.
///
/// Mole's `clean` command is a full-screen interactive TUI. Handing it a plain pipe is not
/// enough: it checks whether stdout is a terminal and, finding a pipe, either disables its
/// interface or refuses to prompt at all. A pty makes it behave exactly as it would in
/// Terminal.app — which is the point, since the user needs to see and answer its
/// confirmations before anything is deleted.
///
/// This replaced an AppleScript handoff that told Terminal.app to run the command. That
/// approach needs Automation permission; without it the call blocks indefinitely and the
/// user sees a window open and nothing happen.
public final class PseudoTerminal: @unchecked Sendable {

    public enum State: Sendable, Equatable {
        case idle
        case running
        case finished(exitCode: Int32)
        case failed(String)
    }

    private var primaryFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private let lock = NSLock()

    /// Raw bytes from the child, delivered on the main actor.
    private let onOutput: @Sendable (Data) -> Void
    private let onStateChange: @Sendable (State) -> Void

    public init(
        onOutput: @escaping @Sendable (Data) -> Void,
        onStateChange: @escaping @Sendable (State) -> Void
    ) {
        self.onOutput = onOutput
        self.onStateChange = onStateChange
    }

    deinit {
        // No lock: `deinit` cannot overlap the event handler, which holds only a weak
        // reference and so fails its `guard let self` once deallocation has begun.
        if let source = readSource {
            // The source owns the descriptor and closes it from its cancel handler.
            source.cancel()
        } else if primaryFD >= 0 {
            // Reading never started, so nothing else will close it.
            close(primaryFD)
        }
    }

    /// Forks a child attached to a new pty and starts streaming its output.
    ///
    /// - Parameter columns/rows: the child sizes its interface from these, so they must be
    ///   set before exec rather than left at the 0×0 a fresh pty reports.
    public func start(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        columns: UInt16 = 100,
        rows: UInt16 = 30
    ) {
        // Everything the child needs is built as C strings *before* the fork.
        //
        // Between fork and exec the child has one thread but inherits every lock the others
        // held at the instant of the fork, including the allocator's — and the thread that
        // would have released it does not exist in the child. POSIX therefore permits only
        // async-signal-safe calls in that window. The previous version read
        // `ProcessInfo.processInfo.environment` and called `strdup` there, both of which
        // allocate.
        //
        // Stated honestly: this was found while chasing an unrelated flaky test and an A/B of
        // 20 runs each showed no difference in that test's failure rate, so it is not the
        // cause of anything observed. It is fixed because it is undefined behaviour that this
        // process is well placed to hit — the app forks Mole while SwiftUI, the scanner's
        // worker pool, and Dispatch all have threads running — and the failure mode, a child
        // deadlocked before exec, would present as a terminal that opens and stays blank
        // forever.
        var childEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment { childEnvironment[key] = value }
        // Declaring a capable terminal keeps colours and cursor addressing switched on.
        childEnvironment["TERM"] = "xterm-256color"

        // A failed duplication has to abort the launch, not truncate the array.
        //
        // `strdup` returning NULL would otherwise terminate `argv` early and hand `execve` a
        // shorter command than the caller asked for — and the arguments this class is given
        // are things like `clean --dry-run`. Losing a trailing `--dry-run` turns a preview
        // into a real deletion. The trigger is allocation failure and so vanishingly rare,
        // but "rare" is the wrong bar for silently running a different command than the one
        // requested.
        let arguments = [executable] + arguments
        let entries = childEnvironment.map { "\($0.key)=\($0.value)" }
        let path = strdup(executable)
        let argv = Self.makeCArray(arguments)
        let envp = Self.makeCArray(entries)
        defer {
            free(path)
            Self.freeCArray(argv, count: arguments.count)
            Self.freeCArray(envp, count: entries.count)
        }
        guard path != nil, let argv, let envp else {
            onStateChange(.failed("Out of memory preparing the command."))
            return
        }

        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var primary: Int32 = 0

        let pid = withUnsafeMutablePointer(to: &size) { sizePtr in
            forkpty(&primary, nil, nil, sizePtr)
        }

        if pid < 0 {
            onStateChange(.failed("Could not allocate a pseudo-terminal."))
            return
        }

        if pid == 0 {
            // Child. Every call below is async-signal-safe -- `signal`, `sigemptyset`,
            // `sigprocmask`, `execve`, `_exit`. Nothing here allocates, and nothing touches
            // Swift or Foundation. Keep it that way.

            // Hand the child a clean signal environment.
            //
            // This is not housekeeping — without it `mole clean` stalls for exactly five
            // minutes. launchd starts GUI applications with SIGTERM set to SIG_IGN, and
            // unlike installed handlers (which exec resets to SIG_DFL) an *ignored*
            // disposition survives execve. Mole wraps its Cloud & Office pass in a shell
            // timeout that spawns a `sleep 300` watchdog, then kills that watchdog and waits
            // on it once the work finishes. Inheriting the ignore made those kills no-ops, so
            // the wait ran the full 300 seconds — output stopped dead after "Cloud & Office"
            // and the window looked frozen. Measured: 375s with the ignore inherited, 81s
            // without. It also silently defeated terminate(), which is how a dry run was
            // found still running a day later.
            //
            // A blocked signal mask is inherited too, so clear that as well.
            for number in 1..<Int32(NSIG) { signal(number, SIG_DFL) }
            var empty = sigset_t()
            sigemptyset(&empty)
            sigprocmask(SIG_SETMASK, &empty, nil)

            execve(path, argv, envp)
            // Only reached if exec failed; _exit rather than exit to skip atexit handlers
            // inherited from the parent.
            _exit(127)
        }

        // Parent.
        lock.lock()
        primaryFD = primary
        childPID = pid
        lock.unlock()

        onStateChange(.running)
        startReading(fd: primary)
        waitForExit(pid: pid)
    }

    /// The child's process group, but only once it is genuinely its own group leader.
    ///
    /// `forkpty` makes the child a session leader, so its pid doubles as its group id — but
    /// `setsid` runs *in the child*, and until it has, `getpgid` reports the group the child
    /// was forked into, which is ours. Signalling that group means signalling this process
    /// and every other child of it. Returning nil for that window lets callers fall back to
    /// signalling the single pid, which is always safe.
    private func ownGroup(of pid: pid_t) -> pid_t? {
        let group = getpgid(pid)
        guard group > 0, group != getpgid(0) else { return nil }
        return group
    }

    /// Builds a NULL-terminated `char *[]`, as `execve` wants it, or nil if any duplication
    /// failed. All-or-nothing: a partly built array would be a silently shortened command.
    private static func makeCArray(_ values: [String])
        -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
            .allocate(capacity: values.count + 1)
        for (index, value) in values.enumerated() {
            guard let duplicate = strdup(value) else {
                // Free by count rather than by scanning for NULL — the NULL that stopped us
                // is exactly what a scan would mistake for the end of the array.
                for earlier in 0..<index { free(array[earlier]) }
                array.deallocate()
                return nil
            }
            array[index] = duplicate
        }
        array[values.count] = nil
        return array
    }

    /// Frees by count, not by scanning to the first NULL, so it stays correct for any array
    /// this class hands it.
    private static func freeCArray(
        _ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, count: Int
    ) {
        guard let array else { return }
        for index in 0..<count { free(array[index]) }
        array.deallocate()
    }

    private func startReading(fd: Int32) {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(fd, &buffer, buffer.count)
            // 0 means the child closed the pty; negative is an error. Either way the
            // stream is done and continuing would spin the event source.
            guard count > 0 else {
                self.stopReading()
                return
            }
            self.onOutput(Data(buffer[0..<count]))
        }

        // Closing a descriptor that a dispatch source is watching is undefined — the source
        // may already be delivering an event for it, and the number can be reused underneath
        // it. The cancel handler is the one place the runtime guarantees no further delivery,
        // so the source owns the descriptor from here on and nothing else may close it.
        source.setCancelHandler { close(fd) }

        // Published *before* `resume`, and under the lock.
        //
        // Resuming first was a real bug, not a tidiness issue: delivery can begin the instant
        // the source is resumed, so for a command that exits immediately the EOF handler could
        // run while `readSource` was still nil. The old `self.readSource?.cancel()` then did
        // nothing, leaving a source that re-arms on a stream at permanent end-of-file and
        // spins a global queue for the lifetime of the object. The window is widest for
        // exactly the cases that matter: a failed exec, or a command that prints and exits.
        lock.lock()
        readSource = source
        lock.unlock()

        source.resume()
    }

    /// Ends output delivery and hands the descriptor to the cancel handler to close.
    ///
    /// Idempotent, because both the EOF handler and `terminate()` can reach it, and they can
    /// reach it concurrently. Whoever takes the source out of `readSource` under the lock is
    /// the one that cancels; everyone else finds nil and does nothing.
    private func stopReading() {
        lock.lock()
        let source = readSource
        readSource = nil
        // The descriptor is about to be closed, so stop handing it to `send`/`resize`.
        primaryFD = -1
        lock.unlock()
        // Cancelled outside the lock: cancellation can run handlers, and holding a lock
        // across that invites a deadlock for no benefit.
        source?.cancel()
    }

    private func waitForExit(pid: pid_t) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            // Decode wait status: low byte carries the signal, second byte the exit code.
            let exitCode = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : status & 0x7F
            self?.onStateChange(.finished(exitCode: exitCode))
        }
    }

    /// Sends keystrokes to the child.
    public func send(_ text: String) {
        lock.lock()
        let fd = primaryFD
        lock.unlock()
        guard fd >= 0, let data = text.data(using: .utf8) else { return }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Tells the child its window changed, so a TUI can re-lay out.
    public func resize(columns: UInt16, rows: UInt16) {
        lock.lock()
        let fd = primaryFD
        lock.unlock()
        guard fd >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = withUnsafeMutablePointer(to: &size) { ioctl(fd, TIOCSWINSZ, $0) }
    }

    /// Interrupts the child, as pressing Ctrl-C in a terminal would.
    ///
    /// Signalling the child pid directly is not enough, which is why the first version's
    /// Stop button did nothing. Mole runs helpers in its own process group, and in raw mode
    /// it reads the interrupt as input rather than receiving a signal at all. So this does
    /// both: writes the literal Ctrl-C byte, which the line discipline turns into SIGINT for
    /// whatever is in the foreground (or which a raw-mode reader handles itself), and
    /// signals the whole process group so children are not left running.
    public func interrupt() {
        lock.lock()
        let fd = primaryFD
        let pid = childPID
        lock.unlock()
        guard pid > 0 else { return }

        if fd >= 0 {
            var byte: UInt8 = 0x03
            _ = write(fd, &byte, 1)
        }

        if let group = ownGroup(of: pid) {
            killpg(group, SIGINT)
        } else {
            kill(pid, SIGINT)
        }
    }

    /// True while the child is still alive.
    public var isAlive: Bool {
        lock.lock()
        let pid = childPID
        lock.unlock()
        guard pid > 0 else { return false }
        // Signal 0 performs the permission and existence checks without sending anything.
        return kill(pid, 0) == 0
    }

    /// Stops the child, escalating until it actually exits.
    ///
    /// A polite interrupt is not reliably enough. Mole's interface is a Go TUI that installs
    /// its own SIGINT handler and, in raw mode, may treat Ctrl-C as ordinary input — so the
    /// Stop button appeared to do nothing even though the signal was being delivered. This
    /// escalates: interrupt, then SIGTERM, then SIGKILL, checking between each so a process
    /// that does quit politely is never killed outright.
    public func stopEscalating(
        onFinished: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        interrupt()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.2) {
            [weak self] in
            guard let self else { return }
            guard self.isAlive else {
                onFinished(true)
                return
            }

            self.signalGroup(SIGTERM)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.2) {
                [weak self] in
                guard let self else { return }
                guard self.isAlive else {
                    onFinished(true)
                    return
                }
                // Cannot be trapped. Reached only when the process ignored both earlier
                // requests, at which point leaving it running is the worse outcome.
                self.signalGroup(SIGKILL)
                onFinished(true)
            }
        }
    }

    private func signalGroup(_ signal: Int32) {
        lock.lock()
        let pid = childPID
        lock.unlock()
        guard pid > 0 else { return }
        if let group = ownGroup(of: pid) { killpg(group, signal) } else { kill(pid, signal) }
    }

    public func terminate() {
        lock.lock()
        let pid = childPID
        lock.unlock()
        // Through stopReading() rather than an unsynchronised `readSource?.cancel()`, so this
        // cannot race the EOF handler doing the same thing. Every caller drops the terminal
        // straight afterwards, so closing the descriptor here costs nothing.
        stopReading()
        guard pid > 0 else { return }
        // Whole group, for the same reason interrupt() does: leaving Mole's helpers running
        // after the window closed would keep deleting with nothing on screen to show it.
        if let group = ownGroup(of: pid) { killpg(group, SIGTERM) } else { kill(pid, SIGTERM) }
    }
}
