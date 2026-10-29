import AppKit
import SwiftUI

struct RemoveMacAIApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  @State private var model = AppModel()

  var body: some Scene {
    Window("RemoveMacAI", id: "main") {
      ContentView()
        .environment(model)
        .frame(minWidth: 860, minHeight: 600)
    }
    .defaultSize(width: 1000, height: 700)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .appInfo) {
        Button("About RemoveMacAI") { AppDelegate.showAbout() }
      }
      CommandGroup(after: .toolbar) {
        Button("Reload") { model.reload(resetChoices: true) }.keyboardShortcut("r")
      }
      CommandGroup(replacing: .help) {
        Button("How RemoveMacAI Works") { model.openWelcome() }
        Divider()
        Link("RemoveMacAI on GitHub", destination: URL(string: "https://github.com/omlahore/RemoveMacAI")!)
        Link("Report a Problem", destination: URL(string: "https://github.com/omlahore/RemoveMacAI/issues/new/choose")!)
      }
    }
  }
}

// Inside an NSObject subclass `version` resolves to NSObject.version(), not this string.
private let appVersion = version

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // A bare binary run from Terminal has no bundle, so it must ask to be a real app.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    // Started outside Launch Services (Homebrew, Terminal), SwiftUI never opens the window on its own.
    DispatchQueue.main.async {
      guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
      let reopen = NSAppleEventDescriptor(
        eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
        targetDescriptor: NSAppleEventDescriptor(processIdentifier: getpid()),
        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
      _ = try? reopen.sendEvent(options: [.noReply], timeout: 1)
    }
    #if DEBUG
      if let dir = ProcessInfo.processInfo.environment["REMOVEMACAI_SNAPSHOTS"] { Snapshots.run(into: dir) }
    #endif
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  static func showAbout() {
    let credits = NSMutableAttributedString(
      string: "Debloats macOS and can undo every change.\n\nThe Apple Intelligence part builds on pared by 4evy, which first mapped Apple's asset service and model sets.",
      attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "RemoveMacAI",
      .applicationVersion: appVersion,
      .version: "",
      .credits: credits,
    ])
  }
}
