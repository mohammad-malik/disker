import Darwin
import Foundation

/// Owns the pty master descriptor, and makes using it and closing it mutually exclusive.
///
/// Passing a bare `Int32` around was not enough. Callers copied the number under a lock,
/// released the lock, and only then made their syscall — and in that gap the read source's
/// cancel handler could close it. A closed descriptor gives a harmless `EBADF`, but the
/// kernel reuses the lowest free number, so another thread opening any file in that window
/// gets the same integer and a keystroke lands in an unrelated file. Holding the descriptor
/// behind this type means "already closed" is a state the caller cannot fail to observe,
/// rather than a race it has to win.
///
/// The lock is held across the syscall deliberately. The writes are keystrokes and one
/// `TIOCSWINSZ`, so they do not block in practice, and the alternative — a reference count —
/// buys nothing for traffic this small.
///
/// Internal rather than private so the suite can test the contract directly. The race it
/// exists to prevent is not reproducible on demand, so the guarantee is pinned here, at the
/// one place that enforces it, rather than through the terminal above it.
final class Descriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(_ fd: Int32) { self.fd = fd }

    /// Runs `body` only while the descriptor is genuinely open. Returns nil once closed.
    @discardableResult
    func use<T>(_ body: (Int32) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return nil }
        return body(fd)
    }

    /// Idempotent, so the cancel handler and a fallback close cannot double-close — which
    /// would be the same descriptor-reuse bug from the other direction.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}

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

    private var descriptor: Descriptor?
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
        } else {
            // Reading never started, so nothing else will close it. Idempotent either way.
            descriptor?.close()
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
        let descriptor = Descriptor(primary)
        lock.lock()
        self.descriptor = descriptor
        childPID = pid
        lock.unlock()

        onStateChange(.running)
        startReading(primary, descriptor: descriptor)
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

    private func startReading(_ fd: Int32, descriptor: Descriptor) {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            // The raw descriptor rather than `descriptor.use` deliberately: Dispatch already
            // guarantees the cancel handler runs only after the last event handler returns,
            // so this cannot overlap the close — and taking the lock here would hold it
            // across a read for the benefit of a race that cannot happen.
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
        source.setCancelHandler { descriptor.close() }

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
        lock.unlock()
        // No need to invalidate the descriptor here: `Descriptor` refuses use once its own
        // close has run, and that close happens in the cancel handler below.
        // Cancelled outside the lock: cancellation can run handlers, and holding a lock
        // across that invites a deadlock for no benefit.
        source?.cancel()
    }

    /// Waits for the child, then reaps it in the same breath as forgetting its pid.
    ///
    /// A pid is only ours until it is reaped; the moment it is, the kernel may hand that
    /// number to somebody else's process. A plain blocking `waitpid` reaped *outside* the
    /// lock, so a `terminate()` that had already read `childPID` could deliver its SIGTERM
    /// after the number had been recycled — and via `ownGroup(of:)` that resolves to a
    /// stranger's process group and `killpg`s it. Reachable in ordinary use: let Mole finish,
    /// then close the sheet.
    ///
    /// So this waits in two steps. `waitid` with `WNOWAIT` blocks until the child exits but
    /// deliberately leaves it waitable — a zombie still owns its pid, so the number cannot be
    /// reused and any signal that slips through lands harmlessly on the corpse. Only then is
    /// the real reap done, under the lock and in the same critical section that clears
    /// `childPID`, so no caller can observe a reaped pid as live.
    private func waitForExit(pid: pid_t) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var info = siginfo_t()
            var waited = true
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 {
                // An interrupted wait says nothing about the child and is simply resumed;
                // anything else means there is no child here to wait for.
                if errno != EINTR {
                    waited = false
                    break
                }
            }

            guard let self else {
                // Nothing else will collect it, so do not leave a zombie behind.
                var status: Int32 = 0
                waitpid(pid, &status, WNOHANG)
                return
            }

            self.lock.lock()
            var status: Int32 = 0
            let reaped = waited ? waitpid(pid, &status, WNOHANG) : -1
            // Forgotten either way. Failing to reap it is all the more reason never to signal
            // that number again, since we no longer know what it refers to.
            self.childPID = -1
            self.lock.unlock()

            guard reaped == pid else {
                // Always end on *some* terminal state. Returning quietly here would leave the
                // sheet showing a run that is still in progress, for ever.
                self.onStateChange(.failed("Lost track of the process; its result is unknown."))
                return
            }
            // Decode wait status: low byte carries the signal, second byte the exit code.
            let exitCode = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : status & 0x7F
            self.onStateChange(.finished(exitCode: exitCode))
        }
    }

    /// Signals the child, holding the lock across the delivery.
    ///
    /// The lock is what makes this safe rather than merely likely to be safe: reaping clears
    /// `childPID` inside the same lock, so a signal either goes out while the pid is still
    /// ours or does not go out at all. Reading the pid, releasing the lock, and *then*
    /// signalling would leave exactly the gap this is here to remove.
    private func signalChild(_ signalNumber: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard childPID > 0 else { return }
        // Whole group where the child owns one, for the same reason interrupt() does: leaving
        // Mole's helpers running after the window closed would keep deleting with nothing on
        // screen to show it.
        if let group = ownGroup(of: childPID) {
            killpg(group, signalNumber)
        } else {
            kill(childPID, signalNumber)
        }
    }

    /// The descriptor holder, or nil if the process was never started.
    private var currentDescriptor: Descriptor? {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    /// Sends keystrokes to the child.
    public func send(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        currentDescriptor?.use { fd in
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
    }

    /// Tells the child its window changed, so a TUI can re-lay out.
    public func resize(columns: UInt16, rows: UInt16) {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        currentDescriptor?.use { fd in
            _ = withUnsafeMutablePointer(to: &size) { ioctl(fd, TIOCSWINSZ, $0) }
        }
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
        currentDescriptor?.use { fd in
            var byte: UInt8 = 0x03
            _ = write(fd, &byte, 1)
        }
        signalChild(SIGINT)
    }

    /// The pid still considered ours, or -1 once the child has been reaped.
    ///
    /// Internal purely so the suite can assert the pid is forgotten at the moment of reaping.
    /// That is the whole of the pid-reuse guarantee, and it is not observable from outside:
    /// `isAlive` returning false proves nothing, since a recycled number would usually be
    /// free at that instant anyway.
    var trackedChildPID: pid_t {
        lock.lock()
        defer { lock.unlock() }
        return childPID
    }

    /// True while the child is still alive.
    ///
    /// The probe runs under the lock for the same reason a signal does: once reaping has
    /// cleared the pid, asking about it would be asking about whoever holds that number now.
    public var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard childPID > 0 else { return false }
        // Signal 0 performs the permission and existence checks without sending anything.
        return kill(childPID, 0) == 0
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

            self.signalChild(SIGTERM)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.2) {
                [weak self] in
                guard let self else { return }
                guard self.isAlive else {
                    onFinished(true)
                    return
                }
                // Cannot be trapped. Reached only when the process ignored both earlier
                // requests, at which point leaving it running is the worse outcome.
                self.signalChild(SIGKILL)
                onFinished(true)
            }
        }
    }

    public func terminate() {
        // Through stopReading() rather than an unsynchronised `readSource?.cancel()`, so this
        // cannot race the EOF handler doing the same thing. Every caller drops the terminal
        // straight afterwards, so closing the descriptor here costs nothing.
        stopReading()
        signalChild(SIGTERM)
    }
}
