import AppKit
import DiskerCore
import SwiftUI

/// Which version's window chrome to build.
///
/// macOS 26 and 27 disagree about what a sidebar is. On 26 it is an inset panel floating over
/// the content, rounded on all four corners and held clear of the window edges. On 27 it is
/// flush: square, hard against the edges, running the full height of the window with the
/// traffic lights on it, the way System Settings and Finder draw it. The window is built for
/// whichever one is running rather than picking a side, so 26 keeps the look it shipped with.
///
/// Asked at runtime rather than with `#available`, because the app builds against the macOS 26
/// SDK — the newest the Command Line Tools ship that can compile SwiftUI at all — and
/// `#available(macOS 27, *)` does not come out true against an SDK that has never heard of 27.
enum SystemLook {
    static let isFlushSidebar = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
}

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
/// All three columns are hosted SwiftUI. `SidebarView`, `DetailView` and `InspectorView`
/// observe the same `@Observable` model directly, so they re-render on their own and the
/// hosting controllers never need their root views replaced. The one thing the shell has to be
/// told is whether the inspector column is open, since that is a property of the split view
/// rather than of anything inside it.
struct SplitShell: NSViewControllerRepresentable {
    @Bindable var model: AppModel
    /// Whether the inspector column should be open.
    ///
    /// Passed in rather than read off the model inside `updateNSViewController`. A
    /// representable's update is driven by its *parent's* body running again, so the
    /// dependency has to be registered where that body can see it — reading the model only
    /// from inside the update means the column never moves.
    var inspectorVisible: Bool

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
    func makeNSViewController(context: Context) -> InspectorAwareSplitViewController {
        let split = InspectorAwareSplitViewController()

        let sidebarHost = NSHostingController(rootView: SidebarView(model: model))
        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: vibrant(sidebarHost, material: .sidebar))
        // The split view parks the sidebar at its minimum, so the minimum is effectively the
        // default width. 200 was too narrow for the longest row — "Recommendations" plus its
        // size badge — which left it reading "Recommen…" out of the box.
        sidebarItem.minimumThickness = 260
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        // Full height on macOS 27, below the titlebar on 26.
        //
        // The two versions want opposite things here. On 26 a sidebar item renders as an inset
        // panel floating over the content, and a full-height one splits the titlebar into two
        // regions — which lays the leading toolbar items out after the sidebar so they slide
        // sideways every time it collapses. Staying below the titlebar avoided that.
        //
        // macOS 27 dropped the floating panel: sidebars are flush, and they run the whole
        // height of the window with the traffic lights sitting on them, as System Settings and
        // Finder do. Held below the titlebar there, the column reads as a slab that starts in
        // the wrong place. The separator goes back to automatic to get the hairline the system
        // draws down the flush edge.
        sidebarItem.allowsFullHeightLayout = SystemLook.isFlushSidebar
        sidebarItem.titlebarSeparatorStyle = .none

        let detailHost = NSHostingController(rootView: DetailView(model: model))
        let detailItem = NSSplitViewItem(viewController: detailHost)
        // macOS 26. Lets the sidebar float *over* this column and insets its safe area to
        // match, instead of pushing it aside — the inset, overlaid sidebar the new design
        // calls for. Set on the content item, never on the sidebar.
        detailItem.automaticallyAdjustsSafeAreaInsets = true

        // The inspector is a split-view item, not SwiftUI's `.inspector` modifier.
        //
        // That modifier draws its own panel inside the content column, and the shape it drew
        // matched nothing else in the window: rounded across the top, square at the bottom
        // left, and clipped to the window's much larger radius at the bottom right — three
        // different corners on one panel, beside a sidebar rounded evenly on all four.
        //
        // And it is a *sidebar* item rather than `inspectorWithViewController:`, which looks
        // like the obvious choice and is not. An inspector item renders flush: full height,
        // square top corner, hard divider. That fixes the mismatched corners by removing the
        // panel altogether, and leaves the window lopsided — floating rounded panel on the
        // left, flush column on the right. A sidebar item on the trailing edge gets the same
        // inset treatment as the leading one, so the two sides are mirror images and every
        // corner in the window comes from the same radius.
        let inspectorHost = NSHostingController(rootView: InspectorView(model: model))
        let inspectorItem = NSSplitViewItem(
            sidebarWithViewController: vibrant(inspectorHost, material: .sidebar))
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 400
        inspectorItem.canCollapse = true
        // Mirrors the leading sidebar on both versions, for the same reasons.
        inspectorItem.allowsFullHeightLayout = SystemLook.isFlushSidebar
        inspectorItem.titlebarSeparatorStyle = SystemLook.isFlushSidebar ? .automatic : .none
        inspectorItem.isCollapsed = !inspectorVisible

        // Empty, fixed-width, and transparent: purely the gap described on `panelEdgeInset`.
        // Collapsed in step with the inspector, since with the panel hidden this would
        // otherwise leave a bare strip of window between the chart and the window edge.
        let spacerItem = NSSplitViewItem(viewController: NSViewController())
        spacerItem.viewController.view = NSView()
        // Zero on macOS 27. The gap balanced a panel the system inset from the window on one
        // side only, and a flush inspector reaches the window edge on purpose — a strip of bare
        // window beyond it would read as a rendering fault. The item stays in the split view at
        // no width rather than being dropped, so the column indices below keep their meaning.
        spacerItem.minimumThickness = SystemLook.isFlushSidebar ? 0 : Self.panelEdgeInset
        spacerItem.maximumThickness = SystemLook.isFlushSidebar ? 0 : Self.panelEdgeInset
        spacerItem.canCollapse = true
        spacerItem.titlebarSeparatorStyle = .none
        // High, not required. A fixed-thickness item is already pinned by its equal minimum
        // and maximum; forcing the holding priority to 1000 as well leaves AppKit no give at
        // all if a resize ever makes the column set unsatisfiable.
        spacerItem.holdingPriority = .defaultHigh
        spacerItem.isCollapsed = !inspectorVisible

        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        split.addSplitViewItem(inspectorItem)
        split.addSplitViewItem(spacerItem)
        // Keeps the preference honest when the *divider* closes the column rather than the
        // toolbar button. Left unnoticed, `showsInspector` would still read "open", so the
        // next click of that button would write `false` against a column that was already
        // shut — one dead click, and only the second one reopened it.
        split.onInspectorCollapseChange = { [weak model] collapsed in
            guard let model, model.sectionSupportsInspector else { return }
            model.showsInspector = !collapsed
        }
        return split
    }

    /// Opens and closes the inspector to follow the model.
    ///
    /// Guarded on the current state: assigning `isCollapsed` unconditionally re-runs the
    /// animation on every unrelated update — every scan-progress tick, of which there are
    /// hundreds a second — and the column visibly stutters.
    func updateNSViewController(
        _ controller: InspectorAwareSplitViewController, context: Context
    ) {
        guard controller.splitViewItems.count == 4 else { return }
        let inspector = controller.splitViewItems[2]
        guard inspector.isCollapsed == inspectorVisible else { return }

        // Silence the write-back for the duration of the animation.
        //
        // Without this the two halves of the binding chase each other: collapsing the column
        // makes AppKit post resize notifications, the write-back reads a half-animated
        // `isCollapsed` and writes the opposite value to the model, which asks for the
        // opposite animation, and so on. The guard on `lastKnownCollapse` does not stop it —
        // a genuine alternation passes that check every time.
        controller.isApplyingCollapse = true
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = true
            inspector.animator().isCollapsed = !inspectorVisible
            controller.splitViewItems[3].animator().isCollapsed = !inspectorVisible
        } completionHandler: {
            // The completion handler carries no actor isolation, but AppKit runs it on the
            // main thread — which is where this flag lives and where it was set.
            MainActor.assumeIsolated { controller.isApplyingCollapse = false }
        }
    }

    /// Width of the strip that holds the inspector's panel clear of the window edge.
    ///
    /// The system insets an inset-sidebar panel from the window itself — but only on the
    /// item's *leading* edge. That is the visible outer edge for the leading sidebar and the
    /// invisible inner one for a trailing sidebar, so the inspector's outer edge landed flush
    /// against the window while the sidebar's stood 8pt clear, and the window read as
    /// lopsided even though the top and bottom gaps matched to the pixel.
    ///
    /// The gap is taken with an empty split item rather than by insetting the panel's own
    /// contents. Insetting from the inside does not work: the system paints across the whole
    /// width of the item regardless, so the panel kept its flush top-right corner and simply
    /// stepped inward a few points below it, with a corner radius that no longer matched the
    /// sidebar's. Making the *item* narrower leaves the system's rendering — radius, specular
    /// edge, vertical insets — exactly as it is on the other side.
    ///
    /// Measured off the leading sidebar rather than invented: no API reports it.
    private static let panelEdgeInset: CGFloat = 8

    /// Wraps a hosted view in behind-window vibrancy that honours Reduce Transparency.
    ///
    /// Only on macOS 26. Apple's guidance is to keep hand-placed `NSVisualEffectView`s out of
    /// sidebar hierarchies because they block the system's own material, and on 27 that is
    /// exactly what happens: the system draws a flush sidebar whose material runs the full
    /// height of the window, under the traffic lights, and a view of ours pinned to the split
    /// item's bounds covers it. On 26 the item supplies no behind-window vibrancy of its own,
    /// which is why this exists at all.
    private func vibrant(
        _ child: NSViewController, material: NSVisualEffectView.Material
    ) -> NSViewController {
        guard !SystemLook.isFlushSidebar else { return child }
        let container = NSViewController()
        container.view = SidebarBackdrop(content: child.view, material: material)
        container.addChild(child)
        return container
    }
}

/// A split view controller that reports when its inspector column is collapsed or reopened.
///
/// KVO on `isCollapsed` would be the obvious route, but its callback carries no actor
/// isolation, so reading the item and writing to the main-actor model from inside it is a data
/// race the compiler rejects outright. `splitViewDidResizeSubviews` is delivered on the main
/// thread by AppKit and covers the same ground: it fires for a divider drag that shuts the
/// column just as it does for a programmatic collapse.
final class InspectorAwareSplitViewController: NSSplitViewController {
    /// Called with the inspector's new collapse state, only when it actually changes and only
    /// when something other than this app's own binding caused it.
    var onInspectorCollapseChange: ((Bool) -> Void)?

    /// Set while the binding is driving the collapse itself, so the resulting notifications
    /// are not reported back as if the user had dragged the divider.
    var isApplyingCollapse = false

    private var lastKnownCollapse: Bool?

    /// Suppresses the scroll edge effect macOS 27 lays over the chart.
    ///
    /// A toolbar's scroll edge effect is the blur it draws over whatever scrolls beneath it.
    /// AppKit installs one per titlebar region, and a region whose items bring their own — the
    /// sidebar, whose list is a scroll view — gets a zero-sized one that draws nothing. The
    /// region holding the chart has no scroll view to hand it to, so on macOS 27 it gets a
    /// full-size one instead: a 52pt band across the top of the pane that blurs the breadcrumb
    /// and the legend sitting in it into an unreadable ghost. On 26 that region's effect was
    /// empty, which is why the band is new.
    ///
    /// A transparent titlebar is what stops it being drawn. Nothing else does: SwiftUI's
    /// `scrollEdgeEffectHidden` has no effect applied from inside the hosted view, at the
    /// chart or at the root, because the effect belongs to AppKit's titlebar rather than to
    /// the hosting view; and `titlebarSeparatorStyle` of `.none` on the item, on the window,
    /// or on both leaves the band exactly as it was.
    ///
    /// Nothing is lost by it here. The window is opaque and the split view starts below the
    /// titlebar, so a transparent titlebar has no content underneath to reveal and the toolbar
    /// keeps its own material. It is still gated to 27: on 26 there is no band to remove, and
    /// the safest change to that version's appearance is none at all.
    ///
    /// Re-asserted on every layout rather than set once. SwiftUI configures the window it
    /// hosts this controller in, and does so *after* `viewWillAppear` — set there, the flag is
    /// silently overwritten and the band comes back.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard SystemLook.isFlushSidebar, let window = view.window,
            !window.titlebarAppearsTransparent
        else { return }
        window.titlebarAppearsTransparent = true
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard splitViewItems.count == 4 else { return }
        let collapsed = splitViewItems[2].isCollapsed
        guard collapsed != lastKnownCollapse else { return }
        // Recorded either way: after a programmatic collapse this is the state the next user
        // drag has to differ from.
        lastKnownCollapse = collapsed
        guard !isApplyingCollapse else { return }
        onInspectorCollapseChange?(collapsed)
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
