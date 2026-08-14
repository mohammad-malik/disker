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
        // The split view parks the sidebar at its minimum, so the minimum is effectively the
        // default width. 200 was too narrow for the longest row — "Recommendations" plus its
        // size badge — which left it reading "Recommen…" out of the box.
        sidebarItem.minimumThickness = 260
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

    /// Wraps a hosted view in behind-window vibrancy that honours Reduce Transparency.
    private func vibrant(
        _ child: NSViewController, material: NSVisualEffectView.Material
    ) -> NSViewController {
        let container = NSViewController()
        container.view = SidebarBackdrop(content: child.view, material: material)
        container.addChild(child)
        return container
    }
}

/// The sidebar's backdrop: behind-window vibrancy, or an opaque fill under Reduce
/// Transparency.
///
/// `.behindWindow` samples the desktop rather than the app's own pixels, and the window
/// server handles it per region — which is why an ordinary opaque AppKit window can still
/// have a translucent sidebar, and why this does not need `isOpaque = false` (that punches
/// through the titlebar and takes the window title with it).
///
/// The accessibility check has to come from `NSWorkspace`. Every other surface in the app
/// reads `\.accessibilityReduceTransparency` from the SwiftUI environment, but this view is
/// installed through `NSViewControllerRepresentable` and sits outside that environment
/// entirely — so the first version of it stayed translucent no matter the setting, which is
/// the regression this fixes. The preference can also be toggled while the app is running,
/// hence the observer.
final class SidebarBackdrop: NSView {
    private let effect = NSVisualEffectView()

    init(content: NSView, material: NSVisualEffectView.Material) {
        super.init(frame: .zero)
        wantsLayer = true

        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Selector-based observers on an `NSObject` are removed automatically when the
        // observer deallocates, so this needs no `deinit` — which is just as well, since
        // touching main-actor state from one is not allowed.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)

        applyTransparencyPreference()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SidebarBackdrop is not loaded from a nib") }

    /// The notification carries no thread guarantee, so hop to the main actor rather than
    /// touching the view tree wherever it happens to land.
    @objc private nonisolated func accessibilityOptionsChanged() {
        Task { @MainActor [weak self] in self?.applyTransparencyPreference() }
    }

    /// Re-resolves the opaque fill, which is appearance-dependent and would otherwise keep
    /// a stale light or dark value after a theme switch.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTransparencyPreference()
    }

    private func applyTransparencyPreference() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effect.isHidden = reduced
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor =
                reduced ? NSColor.windowBackgroundColor.cgColor : NSColor.clear.cgColor
        }
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
