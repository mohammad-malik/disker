import Foundation
import Testing

@testable import DiskerCore

@Suite("Terminal emulator")
struct TerminalEmulatorTests {

    private func feed(_ emulator: TerminalEmulator, _ text: String) {
        emulator.feed(Data(text.utf8))
    }

    @Test("Plain text lands on the grid")
    func plainText() {
        let emulator = TerminalEmulator(rows: 5, columns: 20)
        feed(emulator, "hello")
        #expect(emulator.plainText() == "hello")
    }

    @Test("Carriage return overwrites the current line")
    func carriageReturnOverwrites() {
        let emulator = TerminalEmulator(rows: 5, columns: 20)
        // Progress indicators rely on this. Appending instead would show every frame.
        feed(emulator, "Scanning 10%\rScanning 90%")
        #expect(emulator.plainText() == "Scanning 90%")
    }

    @Test("Colour codes are consumed, not printed")
    func sgrIsNotPrinted() {
        let emulator = TerminalEmulator(rows: 5, columns: 40)
        feed(emulator, "\u{1B}[0;32mgreen\u{1B}[0m plain")
        #expect(emulator.plainText() == "green plain")

        let row = emulator.snapshot()[0]
        #expect(row[0].foreground == 2)
        // The reset must actually clear the attribute, not just stop applying it.
        #expect(row[6].foreground == nil)
    }

    @Test("Cursor positioning writes where it is told")
    func cursorAddressing() {
        let emulator = TerminalEmulator(rows: 5, columns: 20)
        feed(emulator, "\u{1B}[3;5HX")
        let grid = emulator.snapshot()
        // Terminal coordinates are 1-based; row 3 column 5 is grid[2][4].
        #expect(grid[2][4].character == "X")
    }

    @Test("Erase display clears the screen")
    func eraseDisplay() {
        let emulator = TerminalEmulator(rows: 5, columns: 20)
        feed(emulator, "some old output")
        feed(emulator, "\u{1B}[2J\u{1B}[1;1Hfresh")
        #expect(emulator.plainText() == "fresh")
    }

    @Test("Erase line clears to end of line")
    func eraseLine() {
        let emulator = TerminalEmulator(rows: 5, columns: 20)
        feed(emulator, "abcdefgh")
        feed(emulator, "\u{1B}[1;4H\u{1B}[K")
        #expect(emulator.plainText() == "abc")
    }

    @Test("Redraw in place does not accumulate frames")
    func redrawInPlaceReplacesContent() {
        let emulator = TerminalEmulator(rows: 6, columns: 30)
        // The pattern a menu-driven TUI uses: home, clear, draw.
        for frame in 1...5 {
            feed(emulator, "\u{1B}[H\u{1B}[2JFrame \(frame)")
        }
        // Stripping escapes and appending would leave all five frames stacked up.
        #expect(emulator.plainText() == "Frame 5")
    }

    @Test("Output past the last row scrolls")
    func scrolling() {
        let emulator = TerminalEmulator(rows: 3, columns: 20)
        feed(emulator, "one\r\ntwo\r\nthree\r\nfour")
        // The first line falls off the top rather than the last being dropped.
        #expect(emulator.plainText() == "two\nthree\nfour")
    }

    @Test("Lines scrolled off the top are kept as history")
    func scrollbackRetainsHistory() {
        let emulator = TerminalEmulator(rows: 3, columns: 20)
        feed(emulator, "one\r\ntwo\r\nthree\r\nfour\r\nfive")

        // The live screen still shows only the last three lines...
        #expect(emulator.plainText() == "three\nfour\nfive")

        // ...but nothing is lost. Without this, `mole clean` prints far more than a
        // screenful and everything above it was discarded as it arrived, leaving the
        // surrounding ScrollView with nothing to scroll.
        let all = emulator.displayLines().map { String($0.map(\.character)).trimmingCharacters(in: .whitespaces) }
        #expect(all == ["one", "two", "three", "four", "five"])
    }

    @Test("History is bounded")
    func scrollbackIsBounded() {
        let rows = 3
        let emulator = TerminalEmulator(rows: rows, columns: 10)
        for index in 0..<20000 {
            feed(emulator, "line\(index)\r\n")
        }
        // A long-running command must not grow memory without limit. The cap is the 5000-line
        // limit plus one trim chunk of slack plus the live screen: trimming a single line per
        // overflow shifts the whole buffer every time, which is quadratic and took the suite
        // from 9s to 47s, so the excess is dropped in batches instead.
        #expect(emulator.displayLines().count <= 5000 + 512 + rows)
        // ...and the limit is actually reached, so this is a real cap rather than a buffer
        // that simply never filled.
        #expect(emulator.displayLines().count >= 5000)
    }

    @Test("Full-screen redraws do not accumulate as history")
    func alternateScreenIsNotRecorded() {
        let emulator = TerminalEmulator(rows: 4, columns: 30)
        feed(emulator, "\u{1B}[?1049h")
        for frame in 1...20 {
            feed(emulator, "\u{1B}[H\u{1B}[2JFrame \(frame)\r\n")
        }
        // Scrolling back through a menu should not show every intermediate repaint.
        let text = emulator.displayLines()
            .map { String($0.map(\.character)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        #expect(text == ["Frame 20"])
    }

    @Test("Escape sequences split across reads still work")
    func splitSequences() {
        let emulator = TerminalEmulator(rows: 5, columns: 20)
        // A pty read can end mid-sequence; treating the fragment as text would print junk.
        emulator.feed(Data("\u{1B}[0;3".utf8))
        emulator.feed(Data("2mgreen".utf8))
        #expect(emulator.plainText() == "green")
        #expect(emulator.snapshot()[0][0].foreground == 2)
    }

    @Test("Multi-byte UTF-8 split across reads is reassembled")
    func splitUTF8() {
        let emulator = TerminalEmulator(rows: 5, columns: 20)
        let arrow = Array("→".utf8)
        emulator.feed(Data(arrow[0..<1]))
        emulator.feed(Data(arrow[1...]))
        // Mole's output is full of arrows and box-drawing characters.
        #expect(emulator.plainText() == "→")
    }

    @Test("Alternate screen entry starts clean")
    func alternateScreenClears() {
        let emulator = TerminalEmulator(rows: 5, columns: 20)
        feed(emulator, "shell history here")
        feed(emulator, "\u{1B}[?1049h")
        feed(emulator, "TUI")
        #expect(emulator.plainText() == "TUI")
    }

    @Test("Unknown sequences are swallowed rather than printed")
    func unknownSequencesAreSwallowed() {
        let emulator = TerminalEmulator(rows: 5, columns: 30)
        // Scroll region and cursor-hide: not implemented, but must not leak into the output.
        feed(emulator, "\u{1B}[1;20r\u{1B}[?25lvisible")
        #expect(emulator.plainText() == "visible")
    }

    @Test("Resize preserves existing content")
    func resizeKeepsContent() {
        let emulator = TerminalEmulator(rows: 5, columns: 20)
        feed(emulator, "keep me")
        emulator.resize(rows: 10, columns: 40)
        #expect(emulator.plainText() == "keep me")
        #expect(emulator.rows == 10)
        #expect(emulator.columns == 40)
    }

    @Test("Real Mole output renders without escape residue")
    func realMoleOutput() {
        let emulator = TerminalEmulator(rows: 10, columns: 80)
        // Captured from `mole clean --dry-run` on this machine.
        feed(
            emulator,
            "\u{1B}[1;35m➤ User essentials\u{1B}[0m\r\n"
                + "  \u{1B}[0;33m→\u{1B}[0m User app cache 111 items\u{1B}[0m, "
                + "\u{1B}[0;33m913.6MB\u{1B}[0m \u{1B}[0;33mdry\u{1B}[0m\r\n")

        let text = emulator.plainText()
        #expect(text.contains("➤ User essentials"))
        #expect(text.contains("913.6MB"))
        #expect(!text.contains("\u{1B}"))
        #expect(!text.contains("[0;33m"))
    }
}
