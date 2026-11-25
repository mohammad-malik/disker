import Foundation

/// Looks up the translation of a fixed English string, such as a tweak's title,
/// in the app's Localization/<language>.lproj. Gives back the English when
/// there is none, and always from the bare command-line binary.
func L(_ s: String) -> String {
  guard !s.isEmpty else { return s }
  return Bundle.main.localizedString(forKey: s, value: s, table: nil)
}

/// A size for the window: the number in the region's format, the unit in the app's language.
enum UISize {
  static func of(_ bytes: Int64) -> String {
    let s = Term.size(bytes)
    let unit: String
    if s.hasSuffix(" GB") { unit = L("GB") } else if s.hasSuffix(" MB") { unit = L("MB") } else { return s }
    let number = s.dropLast(3).replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
    return number + " " + unit
  }
}

/// Translates a message the engine builds from parts, such as a storage
/// caveat that names apps, and anything else with a fixed English text.
func localizedMessage(_ s: String) -> String {
  let prefix = "Its sound library stays, because ", suffix = " uses it too."
  if s.hasPrefix(prefix) && s.hasSuffix(suffix) {
    let names = String(s.dropFirst(prefix.count).dropLast(suffix.count))
      .replacingOccurrences(of: " and ", with: L(" and "))
    return String(localized: "Its sound library stays, because \(names) uses it too.")
  }
  return L(s)
}
