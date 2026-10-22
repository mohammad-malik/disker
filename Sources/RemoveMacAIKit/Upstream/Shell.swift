import Foundation

enum Shell {
  struct Result {
    let status: Int32
    let output: String
    var ok: Bool { status == 0 }
  }

  /// Runs a program directly, without a shell, and returns its combined output.
  @discardableResult
  static func run(_ path: String, _ arguments: [String]) -> Result {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return Result(status: -1, output: "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
  }

  /// Quotes one argument for /bin/sh.
  static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

  /// Runs shell commands as root after one macOS password prompt. From a
  /// terminal, sudo asks instead. Every command runs even when an earlier one
  /// fails; the result fails if any of them did.
  static func admin(_ commands: [String], prompt: String) -> Result {
    guard !commands.isEmpty else { return Result(status: 0, output: "") }
    let script = adminScript(commands)
    if getuid() == 0 { return run("/bin/sh", ["-c", script]) }
    if isatty(STDIN_FILENO) == 1 && !Shell.inApp {
      return run("/usr/bin/sudo", ["/bin/sh", "-c", script])
    }
    let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let promptText = prompt.replacingOccurrences(of: "\"", with: "'")
    return run("/usr/bin/osascript", [
      "-e", "do shell script \"\(escaped)\" with prompt \"\(promptText)\" with administrator privileges",
    ])
  }

  static func adminScript(_ commands: [String]) -> String {
    (["rc=0"] + commands.map { "( \($0) ) || rc=1" } + ["exit $rc"]).joined(separator: "; ")
  }

  /// A readable reason for a failed administrator step. osascript prefixes
  /// "0:390: execution error:" and appends the error number.
  static func adminError(_ result: Result) -> String {
    var text = result.output.trimmed
    if text.hasSuffix("(-128)") { return "Cancelled, so nothing that needs your password changed." }
    if let range = text.range(of: "execution error: ") { text = String(text[range.upperBound...]) }
    if let paren = text.range(of: #" \(-?\d+\)$"#, options: .regularExpression) { text.removeSubrange(paren) }
    return text
  }

  /// Set by the app, which has no terminal for sudo.
  static var inApp = false

  /// Quits and restarts processes that only read their settings at launch.
  static func restart(_ names: [String]) {
    for name in Set(names) { run("/usr/bin/killall", [name]) }
  }
}
