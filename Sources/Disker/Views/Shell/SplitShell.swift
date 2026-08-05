import AppKit
import DiskerCore
import SwiftUI

/// The window's split view, in AppKit rather than SwiftUI.
///
/// `NavigationSplitView` paints opaque column backgrounds, and SwiftUI offers no way to opt
/// out. Four routes to behind-window translucency were tried through it and none reached the
/// screen: clearing `NSWindow.backgroundColor`, an `NSVisualEffectView` installed via
/// `containerBackground(for: .window)`, hiding the sidebar list's scroll background so that
/// backdrop could show through, and a SwiftUI `.ultraThinMaterial` as the window's container
/// background. Every one of them ended up beneath an opaque pane.
///
/// `NSSplitViewItem(sidebarWithViewController:)` is the piece that actually does it. A real
/// sidebar item brings its own vibrancy — the same mechanism Finder and Mail use — so the
/// desktop reaches the sidebar without us installing a material of our own. That matters:
/// Apple's guidance is to *remove* `NSVisualEffectView`s from sidebar hierarchies, because a
/// hand-placed one blocks the system's Liquid Glass. We let the split item supply it.
///
/// The two columns are hosted SwiftUI. Both `SidebarView` and `DetailView` observe the same
/// `@Observable` model directly, so they re-render on their own and the hosting controllers
/// never need their root views replaced.
struct SplitShell: NSViewControllerRepresentable {
    @Bindable var model: AppModel

    /// The window is deliberately left opaque.
    ///
    /// Setting `isOpaque = false` and clearing `backgroundColor` here does produce genuine
    /// transparency — and that is the problem. It punches a hole through every region
    /// neither AppKit nor SwiftUI paints, starting with the titlebar: the desktop reads
    /// straight through the toolbar strip and the window title disappears entirely. The
    /// sidebar still does not sample the desktop even then, so the cost buys nothing.
    ///
    /// What the AppKit shell *does* buy is the inset, floating sidebar the new design calls
    /// for, which `NavigationSplitView` would not give up.
    func makeNSViewController(context: Context) -> NSSplitViewController {
        let split = NSSplitViewController()

        let sidebarHost = NSHostingController(rootView: SidebarView(model: model))
        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: vibrant(sidebarHost, material: .sidebar))
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        // A full-height sidebar splits the titlebar into two regions, so leading toolbar
        // items are laid out after the sidebar and slide sideways every time it collapses.
        // Keeping the sidebar below the titlebar leaves one continuous region, which pins
        // those items next to the traffic lights.
        sidebarItem.allowsFullHeightLayout = false
        sidebarItem.titlebarSeparatorStyle = .none

        let detailHost = NSHostingController(rootView: DetailView(model: model))
        let detailItem = NSSplitViewItem(viewController: detailHost)
        // macOS 26. Lets the sidebar float *over* this column and insets its safe area to
        // match, instead of pushing it aside — the inset, overlaid sidebar the new design
        // calls for. Set on the content item, never on the sidebar.
        detailItem.automaticallyAdjustsSafeAreaInsets = true

        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        return split
    }

    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {}

    /// Wraps a hosted view in behind-window vibrancy.
    ///
    /// `.behindWindow` samples the desktop rather than the app's own pixels, and the window
    /// server handles it per-region — which is why an ordinary opaque AppKit window can
    /// still have a translucent sidebar. That is the whole reason this does not need
    /// `isOpaque = false`, which punches a hole through the titlebar and takes the window
    /// title with it.
    private func vibrant(
        _ child: NSViewController, material: NSVisualEffectView.Material
    ) -> NSViewController {
        let container = NSViewController()
        let effect = NSVisualEffectView()
        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        container.view = effect

        container.addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: effect.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return container
    }
}

extension NSSplitViewController {
    /// Collapses or expands the front window's sidebar. `NavigationSplitView` supplied this
    /// control for free; an AppKit split view does not.
    ///
    /// Two obvious routes are wrong. `NSApp.sendAction(#selector(toggleSidebar(_:)))` and
    /// `firstResponder.tryToPerform(...)` both walk the responder chain, and the first
    /// responder here lives inside the sidebar's own list — so collapsing the sidebar takes
    /// it out of the chain and every later invocation has nothing to deliver to. That was
    /// the bug where the sidebar closed once and could never be reopened. Walking down
    /// `window.contentViewController.children` fails too: SwiftUI does not necessarily
    /// install a representable's controller as a child of that tree.
    ///
    /// A global holding the last-created controller does work, but it is wrong with more
    /// than one window — every new window overwrites it, so the front window's toolbar can
    /// end up toggling a different window's sidebar. Resolving from the key window's view
    /// tree keeps the action scoped to the window the user is actually looking at.
    static func toggleSidebarFromToolbar() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
            let split = window.contentView?.enclosingSplitViewController,
            let sidebar = split.splitViewItems.first
        else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = true
            sidebar.animator().isCollapsed.toggle()
        }
    }
}

extension NSView {
    /// The controller of the first `NSSplitView` in this subtree.
    ///
    /// Goes through the *view* hierarchy rather than the view-controller hierarchy, since
    /// that is the one SwiftUI is guaranteed to have installed. `NSSplitViewController`
    /// makes itself its split view's delegate, which is what makes this resolvable.
    var enclosingSplitViewController: NSSplitViewController? {
        if let split = self as? NSSplitView,
            let controller = split.delegate as? NSSplitViewController
        {
            return controller
        }
        for subview in subviews {
            if let found = subview.enclosingSplitViewController { return found }
        }
        return nil
    }
}
