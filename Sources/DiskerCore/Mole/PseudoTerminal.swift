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
        readSource?.cancel()
        if primaryFD >= 0 { close(primaryFD) }
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
            // Child. Only async-signal-safe work belongs here; anything that allocates or
            // takes a lock can deadlock against state held by the parent at fork time.

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

            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment { env[key] = value }
            // Declaring a capable terminal keeps colours and cursor addressing switched on.
            env["TERM"] = "xterm-256color"

            let envStrings = env.map { "\($0.key)=\($0.value)" }
            var envPointers: [UnsafeMutablePointer<CChar>?] = envStrings.map {
                strdup($0)
            }
            envPointers.append(nil)

            var argPointers: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map {
                strdup($0)
            }
            argPointers.append(nil)

            execve(executable, &argPointers, &envPointers)
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
                self.readSource?.cancel()
                return
            }
            self.onOutput(Data(buffer[0..<count]))
        }
        source.resume()
        readSource = source
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

        // forkpty makes the child a session leader, so its pid is also its group id.
        let group = getpgid(pid)
        if group > 0 {
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
        let group = getpgid(pid)
        if group > 0 { killpg(group, signal) } else { kill(pid, signal) }
    }

    public func terminate() {
        lock.lock()
        let pid = childPID
        lock.unlock()
        readSource?.cancel()
        guard pid > 0 else { return }
        // Whole group, for the same reason interrupt() does: leaving Mole's helpers running
        // after the window closed would keep deleting with nothing on screen to show it.
        let group = getpgid(pid)
        if group > 0 { killpg(group, SIGTERM) } else { kill(pid, SIGTERM) }
    }
}
