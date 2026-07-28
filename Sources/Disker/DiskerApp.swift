import SwiftUI

@main
struct DiskerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 840)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Disker")
                .font(.largeTitle.weight(.semibold))
            Text("Scaffold running")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
