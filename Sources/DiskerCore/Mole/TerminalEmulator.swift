import Foundation

/// A single character cell on the emulated screen.
public struct TerminalCell: Sendable, Equatable {
    public var character: Character = " "
    /// ANSI colour index (0–255), or nil for the default foreground.
    public var foreground: UInt8?
    public var background: UInt8?
    public var bold: Bool = false
    public var inverse: Bool = false

    public init(
        character: Character = " ",
        foreground: UInt8? = nil,
        background: UInt8? = nil,
        bold: Bool = false,
        inverse: Bool = false
    ) {
        self.character = character
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.inverse = inverse
    }

    public static let blank = TerminalCell()
}

/// A minimal but correct VT100-family screen emulator.
///
/// Stripping escape codes and appending the text is not sufficient for a program like Mole,
/// whose interface redraws in place: it moves the cursor up, overwrites lines, and clears
/// regions. Treated as a stream, that produces a garbled pile of every frame ever drawn.
/// A grid the escape sequences mutate is the only way the output reads correctly.
///
/// Scope is deliberately limited to what a menu-driven TUI actually uses — cursor movement,
/// erase, SGR colour, alternate screen. Unrecognised sequences are consumed and discarded
/// rather than printed, so an unsupported code leaves a gap instead of spraying literal
/// escape characters across the view.
public final class TerminalEmulator: @unchecked Sendable {

    public private(set) var rows: Int
    public private(set) var columns: Int
    public private(set) var grid: [[TerminalCell]]

    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursor: (row: Int, column: Int)?
    private var current = TerminalCell()
    private let lock = NSLock()

    /// Lines that have scrolled off the top.
    ///
    /// Without this the emulator was a fixed viewport: `mole clean` prints well over a
    /// screenful, so everything above the last 34 lines was discarded as it arrived and the
    /// surrounding ScrollView had nothing to scroll. History has to be retained, not just
    /// displayed.
    private var scrollback: [[TerminalCell]] = []

    /// Bounded so a long-running command cannot grow memory without limit.
    private let scrollbackLimit = 5000
    /// Slack before trimming, so the cost is amortised rather than paid per line.
    private static let trimChunk = 512

    /// True while a full-screen TUI is drawing.
    ///
    /// Those programs redraw in place, so their frames must not accumulate as history —
    /// scrolling back through a menu would otherwise show every intermediate repaint.
    private var inAlternateScreen = false

    /// Bytes that arrived mid-sequence and need the next chunk to complete.
    private var pending: [UInt8] = []
    private var utf8Buffer: [UInt8] = []

    public init(rows: Int = 30, columns: Int = 100) {
        self.rows = rows
        self.columns = columns
        grid = Array(
            repeating: Array(repeating: TerminalCell.blank, count: columns), count: rows)
    }

    /// The live screen only.
    public func snapshot() -> [[TerminalCell]] {
        lock.lock()
        defer { lock.unlock() }
        return grid
    }

    /// Scrollback followed by the live screen — what the view renders.
    ///
    /// Trailing blank rows are trimmed so a mostly-empty screen does not leave a large gap
    /// under the last line of output.
    public func displayLines() -> [[TerminalCell]] {
        lock.lock()
        defer { lock.unlock() }

        var lines = scrollback + grid
        while let last = lines.last, last.allSatisfy({ $0.character == " " }) {
            lines.removeLast()
        }
        return lines
    }

    /// Rendered text, trailing blank lines removed.
    public func plainText() -> String {
        snapshot()
            .map { row in
                String(row.map(\.character)).replacingOccurrences(
                    of: "\\s+$", with: "", options: .regularExpression)
            }
            .reversed()
            .drop { $0.isEmpty }
            .reversed()
            .joined(separator: "\n")
    }

    public func resize(rows newRows: Int, columns newColumns: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard newRows > 0, newColumns > 0 else { return }
        var resized = Array(
            repeating: Array(repeating: TerminalCell.blank, count: newColumns), count: newRows)
        for row in 0..<min(rows, newRows) {
            for column in 0..<min(columns, newColumns) {
                resized[row][column] = grid[row][column]
            }
        }
        grid = resized
        rows = newRows
        columns = newColumns
        cursorRow = min(cursorRow, newRows - 1)
        cursorColumn = min(cursorColumn, newColumns - 1)
    }

    public func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        let bytes = pending + Array(data)
        pending = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]

            if byte == 0x1B {  // ESC
                // A sequence may be split across reads; stash it and wait for the rest.
                guard let consumed = handleEscape(bytes, from: index) else {
                    pending = Array(bytes[index...])
                    return
                }
                index += consumed
                continue
            }

            index += 1
            handleByte(byte)
        }
    }

    // MARK: - Plain bytes

    private func handleByte(_ byte: UInt8) {
        switch byte {
        case 0x0A:  // \n
            lineFeed()
        case 0x0D:  // \r
            cursorColumn = 0
        case 0x08:  // backspace
            cursorColumn = max(0, cursorColumn - 1)
        case 0x09:  // tab
            cursorColumn = min(columns - 1, (cursorColumn / 8 + 1) * 8)
        case 0x07:  // bell
            break
        default:
            guard byte >= 0x20 else { break }
            // Multi-byte UTF-8 has to be accumulated before it can become a Character;
            // Mole's output is full of box-drawing glyphs and arrows.
            utf8Buffer.append(byte)
            if let text = String(bytes: utf8Buffer, encoding: .utf8), let character = text.first {
                utf8Buffer = []
                put(character)
            } else if utf8Buffer.count >= 4 {
                utf8Buffer = []  // Not valid UTF-8; drop rather than accumulate forever.
            }
        }
    }

    private func put(_ character: Character) {
        if cursorColumn >= columns {
            cursorColumn = 0
            lineFeed()
        }
        guard cursorRow < rows, cursorColumn < columns else { return }
        var cell = current
        cell.character = character
        grid[cursorRow][cursorColumn] = cell
        cursorColumn += 1
    }

    private func lineFeed() {
        cursorRow += 1
        if cursorRow >= rows {
            let departing = grid.removeFirst()
            // Only a streaming program's output is history worth keeping.
            if !inAlternateScreen {
                scrollback.append(departing)
                // Trimmed in batches. Removing one line per overflow shifts the whole buffer
                // every time, which is quadratic over a long run — enough to be measurable
                // on a command that prints thousands of lines.
                if scrollback.count > scrollbackLimit + Self.trimChunk {
                    scrollback.removeFirst(scrollback.count - scrollbackLimit)
                }
            }
            grid.append(Array(repeating: TerminalCell.blank, count: columns))
            cursorRow = rows - 1
        }
    }

    // MARK: - Escape sequences

    /// Returns the number of bytes consumed, or nil if the sequence is incomplete.
    private func handleEscape(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start + 1 < bytes.count else { return nil }
        let next = bytes[start + 1]

        switch next {
        case UInt8(ascii: "["):
            return handleCSI(bytes, from: start)
        case UInt8(ascii: "]"):
            // OSC — window title and similar. Runs until BEL or ST.
            var index = start + 2
            while index < bytes.count {
                if bytes[index] == 0x07 { return index - start + 1 }
                if bytes[index] == 0x1B, index + 1 < bytes.count,
                    bytes[index + 1] == UInt8(ascii: "\\")
                {
                    return index - start + 2
                }
                index += 1
            }
            return nil
        case UInt8(ascii: "7"):
            savedCursor = (cursorRow, cursorColumn)
            return 2
        case UInt8(ascii: "8"):
            if let saved = savedCursor {
                cursorRow = saved.row
                cursorColumn = saved.column
            }
            return 2
        case UInt8(ascii: "("), UInt8(ascii: ")"):
            return start + 2 < bytes.count ? 3 : nil  // charset selection, ignored
        case UInt8(ascii: "M"):
            cursorRow = max(0, cursorRow - 1)
            return 2
        default:
            return 2  // Unknown two-byte escape: consume and move on.
        }
    }

    private func handleCSI(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 2
        var parameters: [UInt8] = []
        var isPrivate = false

        if index < bytes.count, bytes[index] == UInt8(ascii: "?") {
            isPrivate = true
            index += 1
        }

        // Parameter bytes run until the final byte in 0x40...0x7E.
        while index < bytes.count, bytes[index] < 0x40 || bytes[index] > 0x7E {
            parameters.append(bytes[index])
            index += 1
        }
        guard index < bytes.count else { return nil }

        let final = bytes[index]
        let text = String(decoding: parameters, as: UTF8.self)
        let values = text.split(separator: ";").map { Int($0) ?? 0 }

        apply(final: final, values: values, isPrivate: isPrivate)
        return index - start + 1
    }

    private func apply(final: UInt8, values: [Int], isPrivate: Bool) {
        func value(_ index: Int, default fallback: Int) -> Int {
            index < values.count && values[index] > 0 ? values[index] : fallback
        }

        switch Character(UnicodeScalar(final)) {
        case "A": cursorRow = max(0, cursorRow - value(0, default: 1))
        case "B": cursorRow = min(rows - 1, cursorRow + value(0, default: 1))
        case "C": cursorColumn = min(columns - 1, cursorColumn + value(0, default: 1))
        case "D": cursorColumn = max(0, cursorColumn - value(0, default: 1))
        case "E":
            cursorRow = min(rows - 1, cursorRow + value(0, default: 1))
            cursorColumn = 0
        case "F":
            cursorRow = max(0, cursorRow - value(0, default: 1))
            cursorColumn = 0
        case "G":
            cursorColumn = min(columns - 1, max(0, value(0, default: 1) - 1))
        case "H", "f":
            cursorRow = min(rows - 1, max(0, value(0, default: 1) - 1))
            cursorColumn = min(columns - 1, max(0, value(1, default: 1) - 1))
        case "J":
            eraseDisplay(mode: values.first ?? 0)
        case "K":
            eraseLine(mode: values.first ?? 0)
        case "m":
            applyGraphicRendition(values.isEmpty ? [0] : values)
        case "h" where isPrivate:
            // Entering the alternate buffer starts from a clean screen, and its repaints are
            // kept out of history.
            if values.contains(1049) || values.contains(47) {
                inAlternateScreen = true
                clearAll()
            }
        case "l" where isPrivate:
            if values.contains(1049) || values.contains(47) {
                inAlternateScreen = false
                clearAll()
            }
        case "s":
            savedCursor = (cursorRow, cursorColumn)
        case "u":
            if let saved = savedCursor {
                cursorRow = saved.row
                cursorColumn = saved.column
            }
        default:
            break  // Scroll regions, device queries, etc. — consumed, not rendered.
        }
    }

    private func eraseDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseLine(mode: 0)
            for row in (cursorRow + 1)..<rows {
                grid[row] = Array(repeating: TerminalCell.blank, count: columns)
            }
        case 1:
            eraseLine(mode: 1)
            for row in 0..<cursorRow {
                grid[row] = Array(repeating: TerminalCell.blank, count: columns)
            }
        default:
            clearAll()
        }
    }

    private func eraseLine(mode: Int) {
        guard cursorRow < rows else { return }
        switch mode {
        case 0:
            for column in cursorColumn..<columns { grid[cursorRow][column] = .blank }
        case 1:
            for column in 0...min(cursorColumn, columns - 1) { grid[cursorRow][column] = .blank }
        default:
            grid[cursorRow] = Array(repeating: TerminalCell.blank, count: columns)
        }
    }

    private func clearAll() {
        grid = Array(
            repeating: Array(repeating: TerminalCell.blank, count: columns), count: rows)
        cursorRow = 0
        cursorColumn = 0
    }

    private func applyGraphicRendition(_ values: [Int]) {
        var index = 0
        while index < values.count {
            let code = values[index]
            switch code {
            case 0: current = TerminalCell()
            case 1: current.bold = true
            case 22: current.bold = false
            case 7: current.inverse = true
            case 27: current.inverse = false
            case 30...37: current.foreground = UInt8(code - 30)
            case 90...97: current.foreground = UInt8(code - 90 + 8)
            case 39: current.foreground = nil
            case 40...47: current.background = UInt8(code - 40)
            case 100...107: current.background = UInt8(code - 100 + 8)
            case 49: current.background = nil
            case 38, 48:
                // Extended colour: `38;5;n` (indexed) or `38;2;r;g;b` (truecolour). Only the
                // indexed form maps onto this palette; truecolour collapses to default.
                if index + 1 < values.count, values[index + 1] == 5, index + 2 < values.count {
                    let colour = UInt8(clamping: values[index + 2])
                    if code == 38 { current.foreground = colour } else { current.background = colour }
                    index += 2
                } else if index + 1 < values.count, values[index + 1] == 2 {
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }
}
