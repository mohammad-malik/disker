import Foundation

/// A preference value a tweak sets.
enum PlistValue: Equatable, Codable, CustomStringConvertible {
  case bool(Bool), int(Int), double(Double), string(String)

  var object: CFPropertyList {
    switch self {
    case .bool(let v): return v as CFBoolean
    case .int(let v): return v as CFNumber
    case .double(let v): return v as CFNumber
    case .string(let v): return v as CFString
    }
  }

  /// A stored value, or nil for types tweaks never write.
  init?(_ any: Any?) {
    guard let any else { return nil }
    if let s = any as? String {
      self = .string(s)
    } else if let n = any as? NSNumber {
      if CFGetTypeID(n) == CFBooleanGetTypeID() {
        self = .bool(n.boolValue)
      } else if CFNumberIsFloatType(n) {
        self = .double(n.doubleValue)
      } else {
        self = .int(n.intValue)
      }
    } else {
      return nil
    }
  }

  /// Whether a stored value means the same thing. Booleans and 0/1 are
  /// interchangeable, because `defaults write -int 1` and `-bool true` both happen.
  func matches(_ stored: Any?) -> Bool {
    guard let other = PlistValue(stored) else { return false }
    switch (self, other) {
    case (.bool(let a), .int(let b)), (.int(let b), .bool(let a)): return (b != 0) == a
    case (.double(let a), .int(let b)), (.int(let b), .double(let a)): return a == Double(b)
    default: return self == other
    }
  }

  var description: String {
    switch self {
    case .bool(let v): return v ? "true" : "false"
    case .int(let v): return String(v)
    case .double(let v): return String(v)
    case .string(let v): return "\"\(v)\""
    }
  }
}

/// User preferences, read and written through cfprefsd like `defaults` does.
enum Prefs {
  static let global = "NSGlobalDomain"

  private static func app(_ domain: String) -> CFString {
    domain == global || domain == ".GlobalPreferences" ? kCFPreferencesAnyApplication : domain as CFString
  }

  private static func host(_ currentHost: Bool) -> CFString {
    currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
  }

  /// The value apps see: a forced (managed) value wins over the user's own.
  static func read(_ domain: String, _ key: String, currentHost: Bool = false) -> Any? {
    if currentHost {
      CFPreferencesSynchronize(app(domain), kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
      return CFPreferencesCopyValue(key as CFString, app(domain), kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }
    CFPreferencesAppSynchronize(app(domain))
    return CFPreferencesCopyAppValue(key as CFString, app(domain))
  }

  /// The user's own value, ignoring managed values.
  static func userValue(_ domain: String, _ key: String, currentHost: Bool = false) -> Any? {
    CFPreferencesSynchronize(app(domain), kCFPreferencesCurrentUser, host(currentHost))
    return CFPreferencesCopyValue(key as CFString, app(domain), kCFPreferencesCurrentUser, host(currentHost))
  }

  /// Writes the user's value; nil removes it so the default applies again.
  @discardableResult
  static func write(_ domain: String, _ key: String, _ value: PlistValue?, currentHost: Bool = false) -> Bool {
    CFPreferencesSetValue(key as CFString, value?.object, app(domain), kCFPreferencesCurrentUser, host(currentHost))
    return CFPreferencesSynchronize(app(domain), kCFPreferencesCurrentUser, host(currentHost))
  }

  static func isForced(_ domain: String, _ key: String) -> Bool {
    CFPreferencesAppSynchronize(app(domain))
    return CFPreferencesAppValueIsForced(key as CFString, app(domain))
  }
}
