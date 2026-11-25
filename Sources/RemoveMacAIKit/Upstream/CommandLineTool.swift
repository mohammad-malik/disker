import Foundation

/// The removemacai command for the app from the zip, which the installer and
/// Homebrew put on the PATH but the app doesn't.
enum CommandLineTool {
  static let path = "/usr/local/bin/removemacai"

  /// Links path to the binary after one password prompt.
  static func link(to binary: String, prompt: String) -> Shell.Result {
    Shell.admin(commands(linking: binary, at: path), prompt: prompt)
  }

  /// Checks again as root, since ln -f would delete a file that appeared after the app looked.
  static func commands(linking binary: String, at path: String) -> [String] {
    let folder = (path as NSString).deletingLastPathComponent
    let p = Shell.quote(path)
    return [
      "mkdir -p \(Shell.quote(folder))",
      "if [ -e \(p) ] && [ ! -L \(p) ]; then echo \(Shell.quote("\(path) isn't a link, so it was left alone")) >&2; exit 1; fi; "
        + "ln -sfn \(Shell.quote(binary)) \(p)",
    ]
  }
}
