import AppKit
import SwiftUI

/// Light / dark / follow-system, plus the matching app icon.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// `nil` means inherit, which is what makes "Match System" keep following the setting
    /// after launch rather than freezing whatever was current at startup.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Applies the appearance preference and keeps the Dock icon in step with it.
///
/// Two separate mechanisms are involved. `NSApp.appearance` drives the window chrome and
/// every material inside it. The icon is independent: a bundle carries one static icon, so
/// swapping between the light and dark artwork has to happen at runtime by assigning
/// `NSApp.applicationIconImage`.
///
/// The swap keys off the *effective* appearance rather than the stored preference, because
/// under "Match System" the preference says nothing about which artwork is currently right.
@MainActor
@Observable
final class AppearanceController {
    var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    private static let defaultsKey = "appearanceMode"
    private var observation: NSKeyValueObservation?

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        mode = stored.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    func start() {
        apply()
        // Under "Match System" the app's effective appearance changes without any action
        // from us, and the icon has to follow. KVO on the app's effective appearance covers
        // both the system flipping at sunset and the user changing it in Settings.
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    private func apply() {
        NSApp.appearance = mode.nsAppearance
        updateIcon()
    }

    private func updateIcon() {
        let isDark =
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // The dark-mode artwork is the one designed to sit on a dark Dock, and vice versa.
        let name = isDark ? "AppIcon-Dark" : "AppIcon-Light"
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns"),
            let image = NSImage(contentsOf: url)
        else { return }
        NSApp.applicationIconImage = image
    }
}
