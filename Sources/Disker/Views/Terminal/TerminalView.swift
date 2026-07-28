import DiskerCore
import SwiftUI

/// Renders an emulated terminal screen and forwards keystrokes to the child process.
///
/// Deliberately not a text log. Mole redraws its interface in place, so the view has to show
/// the current state of a grid rather than an accumulating transcript.
struct TerminalScreenView: View {
    let cells: [[TerminalCell]]
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, row in
                Text(attributedRow(row))
                    .font(.system(size: fontSize, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// Builds one line as a single attributed string, coalescing runs that share styling.
    /// Emitting a `Text` per cell would mean tens of thousands of views per frame.
    private func attributedRow(_ row: [TerminalCell]) -> AttributedString {
        var result = AttributedString()
        var run = ""
        var runStyle: TerminalCell?

        func flush() {
            guard !run.isEmpty, let style = runStyle else { return }
            var piece = AttributedString(run)
            // Explicitly light, never `.primary`. A terminal keeps its dark background in
            // both appearances, so a semantic colour would resolve to black in light mode
            // and render the output invisible against it.
            piece.foregroundColor = color(for: style.foreground) ?? Color(white: 0.92)
            if let background = style.background, let colour = color(for: background) {
                piece.backgroundColor = colour
            }
            if style.bold { piece.font = .system(size: fontSize, weight: .bold, design: .monospaced) }
            result.append(piece)
            run = ""
        }

        for cell in row {
            let style = TerminalCell(
                character: " ", foreground: cell.foreground, background: cell.background,
                bold: cell.bold, inverse: cell.inverse)
            if runStyle != style {
                flush()
                runStyle = style
            }
            run.append(cell.character)
        }
        flush()
        return result
    }

    /// Maps the 16 ANSI colours onto the app's palette so the embedded terminal does not
    /// look pasted in from another application.
    private func color(for index: UInt8?) -> Color? {
        guard let index else { return nil }
        switch index {
        case 0: return Color(white: 0.30)
        case 1: return Color(red: 0.97, green: 0.40, blue: 0.45)
        case 2: return Color(red: 0.36, green: 0.85, blue: 0.55)
        case 3: return Color(red: 0.95, green: 0.78, blue: 0.35)
        case 4: return Color(red: 0.38, green: 0.64, blue: 0.99)
        case 5: return Color(red: 0.72, green: 0.52, blue: 0.98)
        case 6: return Color(red: 0.32, green: 0.82, blue: 0.84)
        case 7: return Color(white: 0.85)
        case 8: return Color(white: 0.45)
        case 9: return Color(red: 1.00, green: 0.52, blue: 0.55)
        case 10: return Color(red: 0.50, green: 0.90, blue: 0.64)
        case 11: return Color(red: 1.00, green: 0.85, blue: 0.45)
        case 12: return Color(red: 0.52, green: 0.74, blue: 1.00)
        case 13: return Color(red: 0.82, green: 0.64, blue: 1.00)
        case 14: return Color(red: 0.48, green: 0.90, blue: 0.92)
        case 15: return .white
        default: return Color(white: 0.80)
        }
    }
}

/// Captures keystrokes for the terminal.
///
/// SwiftUI has no way to receive raw key events including arrows, Escape, and control
/// characters, all of which a TUI needs. This drops to AppKit for the key handling only.
struct TerminalKeyCatcher: NSViewRepresentable {
    let onKey: (String) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onKey = onKey
    }

    final class KeyView: NSView {
        var onKey: ((String) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            // Translate the keys a TUI cares about into the byte sequences a terminal sends.
            switch event.keyCode {
            case 126: onKey?("\u{1B}[A")  // up
            case 125: onKey?("\u{1B}[B")  // down
            case 124: onKey?("\u{1B}[C")  // right
            case 123: onKey?("\u{1B}[D")  // left
            case 36: onKey?("\r")  // return
            case 53: onKey?("\u{1B}")  // escape
            case 51: onKey?("\u{7F}")  // delete
            case 48: onKey?("\t")
            default:
                if event.modifierFlags.contains(.control),
                    let characters = event.charactersIgnoringModifiers,
                    let scalar = characters.unicodeScalars.first
                {
                    // Ctrl-A becomes 0x01, and so on — Ctrl-C in particular must reach Mole.
                    let value = scalar.value
                    if value >= 97 && value <= 122 {
                        onKey?(String(UnicodeScalar(value - 96)!))
                        return
                    }
                }
                if let characters = event.characters { onKey?(characters) }
            }
        }
    }
}
