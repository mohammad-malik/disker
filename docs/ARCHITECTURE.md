# How Disker works

Notes for anyone reading or changing the code. Nothing here is needed to use the app.

## Targets

| Target       | What it is                                                                          |
| ------------ | ----------------------------------------------------------------------------------- |
| `DiskerCore` | Scanning, analysis, and Mole integration. No SwiftUI, so it is testable headlessly.  |
| `Disker`     | The SwiftUI app.                                                                    |
| `diskerctl`  | A headless harness for cross-checking the scanner against `du` and `df`.            |

`DiskerCore` deliberately imports no SwiftUI. The scanner can then be exercised and benchmarked
without launching a GUI, which mattered a great deal while Xcode Previews were unavailable.

```sh
swift run diskerctl scan ~/Documents --depth 2
swift run diskerctl volumes
swift run diskerctl recommend
swift run diskerctl mole
```

## Scanning

Traversal uses **`getattrlistbulk(2)`** rather than `FileManager.enumerator`, returning many
directory entries per syscall.

It requests `ATTR_FILE_ALLOCSIZE` — bytes actually on disk — rather than `ATTR_FILE_DATALENGTH`.
Logical length overstates sparse files and understates nothing useful; allocation size is what a
user means by "how much space is this taking".

Fields come back packed without padding, so they are decoded with `loadUnaligned`.

### Volume boundaries

This is the subtlest part of the scanner. **Members of an APFS volume group report identical
`st_dev`**, so the usual "compare device IDs and stop when it changes" technique silently fails
on modern macOS, and following firmlinks counts the data volume twice. An early build reported
427 GB used on a 228 GB disk that way.

Boundaries instead come from `/usr/share/firmlinks` and `getmntinfo(3)`, with
`statfs().f_mntfromname` identifying which volume a path really belongs to. `VolumeBoundaries`
holds this, and the test suite asserts a scan of the system volume cannot exceed its capacity.

### Deduplication

Hardlinks and APFS clones are counted once, keyed on `(device, fileID)`. Only entries with a
link count above one are tracked, which keeps the set small. Which occurrence "wins" is not
defined — it does not affect totals.

### Permissions

`EPERM` is expected, not exceptional. Unreadable directories are counted and reported, so a scan
without Full Disk Access is presented as a lower bound rather than a confidently wrong total.

## Safety

Deleting the wrong thing is the failure mode that matters here, so the rules are explicit and
tested. `SafetyPolicy` is the enforcement point.

- Everything removed goes through `FileManager.trashItem` and registers with `UndoManager`. No
  code path calls `unlink`, `removeItem`, or `rm -rf`.
- **Installed software is never suggested.** Global package-manager roots are excluded:
  `/opt/homebrew/lib/node_modules`, `~/.bun/install/global`, nvm/volta/asdf/rbenv/pyenv version
  directories, Homebrew's Cellar, and others. An early version offered to delete the directory
  holding globally installed CLI tools, which would have uninstalled them.
- **Bundle boundaries stop traversal**, so a `node_modules` vendored inside a `.app` is never
  offered.
- The user's Mole whitelist at `~/.config/mole/whitelist` is honoured. Paths are normalised
  first: scanning produces `/System/Volumes/Data/Users/...` while whitelist entries are written
  as `/Users/...`, and without folding those together no protection ever matched.

`isExcluded` (stop traversing) is deliberately distinct from `containsProtectedContent` (do not
offer this, but keep walking). Conflating them made every ancestor of a protected path protected
too, which pruned the entire home directory from the results.

## Running Mole

Mole is a separate process, located on `PATH` and never bundled. See
[THIRD-PARTY.md](THIRD-PARTY.md) for why that boundary matters legally.

**Mole needs a pty, not a pipe.** It checks `isatty` and will not prompt otherwise, so
`PseudoTerminal` runs it under `forkpty(3)`.

**Its output needs emulating, not stripping.** Mole redraws in place with carriage returns and
cursor addressing; stripping ANSI escapes and appending stacks every frame on top of the last.
`TerminalEmulator` maintains a real character grid with bounded scrollback, and ignores the
alternate screen buffer for history so a menu's repaints do not accumulate.

**Children get default signal dispositions before `exec`.** launchd starts GUI apps with
`SIGTERM` set to `SIG_IGN`, and unlike an installed handler — which `exec` resets — an ignored
disposition survives `execve`. Mole wraps part of its work in a shell timeout that spawns a
`sleep 300` watchdog, kills it when the work finishes, then waits on it. Inheriting the ignore
made those kills no-ops, so the wait ran the full 300 seconds: output stopped dead mid-run and
the window looked frozen. Measured 375s with the ignore inherited, 70–87s without. The same
inheritance left orphaned processes that no `SIGTERM` could reach.

## Interface notes

- `.containerBackground(for: .window)` is required for glass to show through.
  `NavigationSplitView` paints opaque panes above `.background`.
- Chart clicks use `NSEvent.clickCount` via an AppKit view, avoiding the delay SwiftUI adds
  while waiting to disambiguate a double-tap.
- The terminal's key-catching overlay declines hit testing entirely. While it was hit-testable
  the window handed it every mouse event first, and `NSView` forwards the wheel up the responder
  chain rather than across to the scroll view beside it — so the transcript could not be
  scrolled. Focus is kept with a local click monitor instead.
- Recommendation rows are backed by `List`. An earlier `LazyVStack` version with a computed
  `displayPath` recalculated per row per render pushed the app to 70–90% CPU and 3 GB of memory.

## Building and signing

`Tools/bundle.sh` assembles `Disker.app` by hand — compile, lay out the bundle, generate the
icon with `sips`/`iconutil` since `actool` is unavailable outside Xcode, then sign.

macOS keys Full Disk Access to **code signing identity**. A plain ad-hoc signature changes on
every build, revoking the grant each time. `Tools/create-signing-identity.sh` creates one
self-signed certificate in the login keychain so the grant survives rebuilds.

`Tools/release.sh` deliberately does the opposite and signs **ad-hoc**, because that certificate
is trusted only in the keychain that created it; elsewhere the bundle fails validation and
Finder reports the app as damaged, which is harder to get past than the ordinary
unidentified-developer prompt. It packages with `ditto`, which preserves the signature and
symlinks that `zip -r` would mangle.

## Testing

`Tools/test.sh` wires up swift-testing, which needs `-F` plus rpaths to both
`.../Developer/Frameworks` and `.../Developer/usr/lib` when running under Command Line Tools.

`ScanCache`'s directory is injectable specifically so the suite cannot delete the real cached
scan — an early version hard-coded Application Support and did exactly that.
