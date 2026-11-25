import SwiftUI

/// Small pieces that explain things: help popovers, numbered steps, the
/// safety promises and a drawing of the System Settings profile screen.

struct InfoButton: View {
  let title: String
  let text: String
  @State private var shown = false

  var body: some View {
    Button { shown.toggle() } label: {
      Image(systemName: "info.circle").foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .help(L(title))
    .accessibilityLabel("About \(L(title))")
    .popover(isPresented: $shown, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 6) {
        Text(L(title)).font(.headline)
        Text(L(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      .padding(14)
      .frame(width: 300, alignment: .leading)
    }
  }
}

enum Explain {
  static let profile = (
    "Configuration profile",
    "macOS only lets these settings stay locked through a configuration profile, the same thing schools and companies use to manage Macs. RemoveMacAI shows you what's in it, and you install it yourself in System Settings. Remove it there any time, or with Undo."
  )
  static let models = (
    "Apple Intelligence models",
    "The files Apple Intelligence runs on, downloaded by macOS whether you use the features or not. Deleting them frees the space. If you turn a feature back on, macOS downloads what it needs again."
  )
  static let locked = (
    "Kept off by the profile",
    "This setting is held off by the RemoveMacAI profile, so a macOS update or a stray click can't turn it back on. Undo removes the profile and gives you the switch back."
  )
}

struct StepBadge: View {
  let number: Int
  var done = false
  var active = true

  var body: some View {
    ZStack {
      Circle().fill(done ? Color.green : (active ? Color.accentColor : Color.secondary.opacity(0.25)))
      if done {
        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
      } else {
        Text("\(number)").font(.caption.weight(.bold).monospacedDigit())
          .foregroundStyle(active ? Color.white : Color.secondary)
      }
    }
    .frame(width: 22, height: 22)
    .accessibilityHidden(true)
  }
}

struct Promise: Identifiable {
  let id = UUID()
  let symbol: String
  let title: String
  let detail: String
  var tint: Color = .accentColor
}

enum Promises {
  static let all: [Promise] = [
    Promise(symbol: "eye", title: "You see every change first", detail: "Nothing happens until you review the list and click Apply."),
    Promise(symbol: "arrow.uturn.backward", title: "Everything can be undone", detail: "Undo puts every setting back. Deleted models download again when a feature needs them."),
    Promise(symbol: "checkmark.shield", title: "Your Mac stays protected", detail: "System Integrity Protection stays on. Nothing inside /System is touched.", tint: .green),
    Promise(symbol: "wifi.slash", title: "Nothing leaves your Mac", detail: "No account, no analytics, no network requests. The code is public on GitHub.", tint: .green),
  ]
}

struct PromiseCard: View {
  let promise: Promise

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: promise.symbol)
        .font(.title2)
        .foregroundStyle(promise.tint)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 3) {
        Text(L(promise.title)).font(.headline)
        Text(L(promise.detail)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    .accessibilityElement(children: .combine)
  }
}

struct SafetyCard: View {
  @Environment(\.openURL) private var openURL
  var showWelcome: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Safe by design", systemImage: "checkmark.shield.fill")
        .font(.headline)
        .foregroundStyle(.green)
      Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
        GridRow {
          check("You review every change before it happens")
          check("Undo puts everything back")
        }
        GridRow {
          check("System Integrity Protection stays on")
          check("No network requests, no analytics")
        }
      }
      HStack(spacing: 18) {
        Button("Read the code on GitHub") { openURL(URL(string: "https://github.com/omlahore/RemoveMacAI")!) }
        Button("How RemoveMacAI works") { showWelcome() }
      }
      .buttonStyle(.link)
      .font(.callout)
    }
  }

  func check(_ text: LocalizedStringKey) -> some View {
    Label {
      Text(text).foregroundStyle(.primary)
    } icon: {
      Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
    }
    .font(.callout)
  }
}

/// A drawing of System Settings at General > Device Management, with the
/// RemoveMacAI profile and its Install button marked. Drawn, not a
/// screenshot, so it stays sharp and follows light and dark mode.
struct SettingsGuide: View {
  var remove = false
  @State private var pulse = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 10, height: 10)
        Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 10, height: 10)
        Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 10, height: 10)
        Text("System Settings").font(.caption).foregroundStyle(.secondary).padding(.leading, 6)
        Spacer()
      }
      .padding(.horizontal, 10)
      .frame(height: 28)
      .background(.quaternary.opacity(0.6))
      HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 7) {
          ForEach(["Wi-Fi", "Bluetooth", "Network"], id: \.self) { Text(L($0)) }
          Text("General")
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
          ForEach(["Appearance", "Privacy & Security"], id: \.self) { Text(L($0)) }
        }
        .font(.caption)
        .padding(10)
        .frame(width: 120, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.35))
        VStack(alignment: .leading, spacing: 9) {
          Text("General › Device Management").font(.caption).foregroundStyle(.secondary)
          Text(remove ? "Profiles" : "Downloaded").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
          HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
            VStack(alignment: .leading, spacing: 1) {
              Text("RemoveMacAI").font(.caption.weight(.semibold))
              Text(remove ? "Select, then click −" : "Double-click to review").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
          }
          .padding(8)
          .background(RoundedRectangle(cornerRadius: 7).fill(.background))
          .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: pulse ? 3 : 1.5))
          VStack(alignment: .leading, spacing: 8) {
            Text(remove ? "Remove “RemoveMacAI”?" : "“RemoveMacAI” wants to install").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
              Spacer()
              Text("Cancel").font(.caption2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).stroke(.tertiary))
              Text(remove ? "Remove" : "Install…").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor.opacity(0.5), lineWidth: pulse ? 4 : 0).padding(-3))
            }
          }
          .padding(8)
          .background(RoundedRectangle(cornerRadius: 7).fill(.background))
          Spacer(minLength: 0)
        }
        .padding(10)
      }
      .frame(height: 200)
    }
    .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      remove
        ? "System Settings, General, Device Management. Select the RemoveMacAI profile and click the minus button to remove it."
        : "System Settings, General, Device Management. Double-click the RemoveMacAI profile under Downloaded, then click Install.")
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
    }
  }
}
