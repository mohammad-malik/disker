# Disker — notes for coding agents

## Build and test

Pass `--disable-sandbox` to both:

```sh
swift build --disable-sandbox
./Tools/test.sh --disable-sandbox
```

SwiftPM sandboxes its own manifest evaluation with `sandbox-exec`, and macOS will not
nest seatbelt sandboxes. Inside an agent sandbox that means `Package.swift` cannot be
evaluated at all: the build dies with `sandbox-exec: sandbox_apply: Operation not
permitted` before a single source file is compiled, and the errors it prints
first — a missing `SwiftShims` module, an SDK/compiler version mismatch — are
downstream noise, not real problems. The flag disables only SwiftPM's inner sandbox;
whatever sandbox the agent is already running under still applies.

Run tests through `./Tools/test.sh`, never a bare `swift test`. swift-testing ships
inside the Command Line Tools but is not on the default search path, so `swift test`
fails with `no such module 'Testing'`. The script supplies the framework paths and
forwards any extra arguments through to `swift test`.

Interactive flags are unavailable, and there is no Xcode on this machine — Command Line
Tools only. That means no previews, no simulator, and no `xcodebuild`.

## Running the app

```sh
./Tools/bundle.sh && open build/Disker.app
```

`swift build` produces a bare executable. The app needs the bundle layout, icons and
signature that `bundle.sh` applies, and the signing identity is what preserves Full Disk
Access across rebuilds — without it macOS treats each rebuild as a new app and silently
revokes the grant.

## Layout

- `Sources/DiskerCore` — scanning, analysis, Mole integration. No UI, and where nearly
  all the test coverage lives.
- `Sources/Disker` — the app. SwiftUI throughout except the window shell, which is an
  `NSSplitViewController` (`Views/Shell/SplitShell.swift`).
- `Tests/DiskerCoreTests` — swift-testing suites over `DiskerCore`.

## Design constraints worth knowing before touching the UI

Liquid Glass is a chrome material, not a card texture. Apple's rule is that it forms a
functional layer floating *above* the content layer, and does not belong in the content
layer itself. This app follows that literally, and an earlier version did the opposite —
so a few things look like omissions but are deliberate:

- Content surfaces use standard materials. Only the toolbar, sidebar, inspector, sheets
  and a small set of controls floating over the sunburst are glass.
- Nothing draws a border, shadow or gradient on top of `.glassEffect`. The material
  supplies its own adaptive shadow and specular edge; hand-drawn ones are what made the
  previous version read as flat frosted cards.
- The chart deliberately runs *underneath* the floating controls, and the hub is wider
  than the ring hole it sits in. Glass with nothing behind it renders as a dark slab, so
  the overlap is the effect, not an accident.
- Custom glass uses the `regular` variant only, and is tinted in exactly one place.
- Accessibility is not automatic for custom surfaces. `FloatingGlass` switches to
  `Glass.identity` under Reduce Transparency, and `SidebarBackdrop` reads the preference
  from `NSWorkspace` because it sits outside SwiftUI's environment.
