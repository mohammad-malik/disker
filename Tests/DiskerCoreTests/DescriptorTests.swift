import Darwin
import Foundation
import Testing

@testable import DiskerCore

/// The gate that stops a closed pty descriptor from being used.
///
/// `send`, `resize`, and `interrupt` used to copy the descriptor number under a lock, release
/// the lock, and only then make their syscall. In that gap the read source's cancel handler
/// could close it — and because the kernel hands out the lowest free number, any other thread
/// opening a file in that window gets the same integer. A keystroke then lands in an
/// unrelated file rather than in the terminal.
///
/// That race is not reproducible on demand, so what is pinned here is the property that makes
/// it impossible: use and close are mutually exclusive, and use after close does nothing.
@Suite("Descriptor")
struct DescriptorTests {

    /// A real descriptor, so `close` is exercised against the kernel rather than a stand-in.
    private func makeDescriptor() -> (Descriptor, Int32) {
        var fds: [Int32] = [-1, -1]
        pipe(&fds)
        // The read end is left for the caller to close; only the write end is under test.
        close(fds[0])
        return (Descriptor(fds[1]), fds[1])
    }

    @Test("A descriptor is usable while open and yields the body's value")
    func useWhileOpen() {
        let (descriptor, fd) = makeDescriptor()
        defer { descriptor.close() }

        let seen = descriptor.use { $0 }
        #expect(seen == fd)
    }

    @Test("Use after close does nothing and reports nothing")
    func useAfterCloseIsRefused() {
        let (descriptor, _) = makeDescriptor()
        descriptor.close()

        var ran = false
        let result: Int32? = descriptor.use { fd in
            ran = true
            return fd
        }

        // Both matter: the caller must be able to tell it did not happen, and the body must
        // not run at all — running it is what would write to a reused descriptor.
        #expect(result == nil)
        #expect(!ran)
    }

    /// The cancel handler closes, and `deinit` may close again on the path where reading never
    /// started. A second real `close(2)` on the same number is exactly the reuse bug from the
    /// other direction: it would shut a descriptor that now belongs to someone else.
    @Test("Closing twice does not close the number twice")
    func closeIsIdempotent() {
        let (descriptor, fd) = makeDescriptor()

        descriptor.close()
        // Claim the number back. If the second close were to go through, it would close this.
        let replacement = dup(STDIN_FILENO)
        descriptor.close()

        if replacement == fd {
            // The kernel reused the number, which is the case worth proving safe.
            #expect(fcntl(replacement, F_GETFD) != -1, "second close shut a reused descriptor")
        }
        if replacement >= 0 { close(replacement) }
    }

    @Test("Concurrent use and close never runs the body after the close")
    func concurrentUseAndClose() {
        for _ in 0..<200 {
            let (descriptor, _) = makeDescriptor()
            let violations = Violations()

            DispatchQueue.concurrentPerform(iterations: 8) { index in
                if index == 0 {
                    descriptor.close()
                } else {
                    descriptor.use { fd in
                        // Inside `use` the descriptor is guaranteed open, so this must hold.
                        if fcntl(fd, F_GETFD) == -1 { violations.record() }
                    }
                }
            }

            #expect(violations.count == 0)
            descriptor.close()
        }
    }
}

private final class Violations: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    func record() {
        lock.lock()
        total += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}
