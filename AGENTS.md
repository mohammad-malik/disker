# Disker — notes for coding agents

## Build and test

Build and test through the scripts, passing `--disable-sandbox` to both:

```sh
./Tools/build.sh --disable-sandbox
./Tools/test.sh --disable-sandbox
```

A bare `swift build` no longer works on macOS 27, which is why the build goes through a
script now. Two separate gaps in the macOS 27 Command Line Tools, both handled by the
flags `Tools/env.sh` supplies:

- No `libSwiftUIMacros.dylib` ships anywhere on the system, so `@State` cannot expand and
  every SwiftUI file fails with `plugin for module 'SwiftUIMacros' not found`. `env.sh`
  sets `SDKROOT` to the macOS 26 SDK, which declares `State` as a plain property wrapper
  rather than a macro and sidesteps the missing plugin. Export `SDKROOT` yourself to
  override it. `DiskerCore`, `diskerctl` and the tests hold no SwiftUI and compile against
  either SDK, so only the app target needs this.
- swift-testing's `libTestingMacros.dylib` sits one directory below the plugins the
  compiler loads on its own, so `@Test` and `@Suite` fail to expand until `-plugin-path`
  names it.

One consequence worth knowing before writing a version check: an app built against the
macOS 26 SDK does not see `#available(macOS 27, *)` as true when running on 27. Ask
`ProcessInfo.processInfo.isOperatingSystemAtLeast` instead — `SplitShell` does, for the
titlebar workaround described in its own comments.

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
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./Tools/bundle.sh
open build/Disker.app
```

To see a change on screen, capture the window rather than the screen. The window is often
on another Space, where a full-screen `screencapture` catches everything except the app.
Read the window id out of the running process and target it:

```sh
lldb -p $(pgrep -x Disker) --batch -o 'expr -l objc++ -O -i1 -- NSWindow *w=(NSWindow*)[[(id)NSApp windows] objectAtIndex:0]; (id)@(w.windowNumber)' -o detach -o quit
screencapture -x -o -l <windowNumber> shot.png
```

The same `lldb` route is the quickest way to test an AppKit hypothesis: poke the property
on the live window or split view item, capture, and only then write the code. Re-run the
unmodified control before believing a result, since an inactive window and a `setHidden:`
that has not been laid out yet both read as a fix that is not there.

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
