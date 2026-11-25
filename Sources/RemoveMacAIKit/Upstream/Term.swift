import Foundation

enum Term {
  static func colorEnabled(env: [String: String] = ProcessInfo.processInfo.environment, tty: Bool) -> Bool {
    if env["NO_COLOR"] != nil { return false }
    if let forced = env["CLICOLOR_FORCE"] { return forced != "0" }
    return tty
  }

  static let color: Bool = colorEnabled(tty: isatty(STDOUT_FILENO) == 1)
  static let errColor: Bool = colorEnabled(tty: isatty(STDERR_FILENO) == 1)

  static func paint(_ s: String, _ code: String, useColor: Bool) -> String { useColor ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
  static func paint(_ s: String, _ code: String) -> String { paint(s, code, useColor: color) }
  static func errPaint(_ s: String, _ code: String) -> String { paint(s, code, useColor: errColor) }
  static func bold(_ s: String) -> String { paint(s, "1") }
  static func dim(_ s: String) -> String { paint(s, "2") }
  static func green(_ s: String) -> String { paint(s, "32") }
  static func yellow(_ s: String) -> String { paint(s, "33") }
  static func red(_ s: String) -> String { paint(s, "31") }

  static func size(_ bytes: Int64) -> String {
    if bytes <= 0 { return "0 MB" }
    // Anything that would round to "1000 MB" is shown in GB instead.
    if bytes >= 999_500_000 { return String(format: "%.1f GB", Double(bytes) / 1e9) }
    return String(format: "%.0f MB", max(1, Double(bytes) / 1e6))
  }

  /// Pads to a column width, keeping at least one space before the next column.
  static func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
  }

  static func ask(_ question: String) -> Bool {
    print(question + " [y/N] ", terminator: "")
    fflush(stdout)
    guard let answer = readLine() else { return false }
    return ["y", "yes"].contains(answer.lowercased().trimmingCharacters(in: .whitespaces))
  }

  static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((errPaint("error: ", "31") + message + "\n").utf8))
    exit(1)
  }
}
