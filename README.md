# Disker

A macOS disk analyzer with a Liquid Glass interface, an interactive sunburst, and one-button
cleanup through [Mole](https://github.com/tw93/mole).

![Disker showing a full-volume scan as a sunburst chart](docs/screenshot.png)

## What it does

- **Scans a whole volume fast** using `getattrlistbulk(2)`, reporting bytes actually on disk
  rather than logical size.
- **Draws the result as a sunburst** — click a wedge to drill in, hover for detail, with an
  inspector showing the largest items beneath any node.
- **Suggests what to clean**, tiered by how safe it is, and never acts on its own.
- **Runs Mole in-app** in a real terminal emulator, so its prompts (including sudo) work
  without leaving the window.

## Install

Download the latest build from
[Releases](https://github.com/mohammad-malik/disker/releases/latest), unzip, and drag
`Disker.app` to `/Applications`.

The release is ad-hoc signed rather than notarised, so the **first launch needs a right-click →
Open** instead of a double-click. Full instructions, including Full Disk Access, are in
[docs/INSTALL.md](docs/INSTALL.md).

Requires **macOS 26 (Tahoe)** on **Apple Silicon**. Or [build it yourself](#building) — two
commands, no Apple developer account needed.

## Requirements

- macOS 26 (Tahoe) — the Liquid Glass APIs are used directly, with no fallback path.
- Apple Silicon. The release build is `arm64` only.
- Command Line Tools for Xcode, to build from source. **Xcode itself is not required**; the app
  bundle is assembled by hand in `Tools/bundle.sh`.
- [Mole](https://github.com/tw93/mole) (`brew install mole`) — optional. Without it the
  scanner and chart work normally and the cleanup features report that it is missing.

## Building

```sh
./Tools/create-signing-identity.sh   # once — see "Full Disk Access" below
./Tools/bundle.sh                    # produces build/Disker.app
./Tools/test.sh                      # runs the test suite
open build/Disker.app
```

`Tools/release.sh <version>` produces the distributable zip. It signs ad-hoc rather than with
your local identity, because that certificate is trusted only in the keychain that created it —
elsewhere the bundle fails validation and Finder calls the app damaged.

### Full Disk Access

A disk analyzer that cannot read protected directories reports numbers that are quietly too
low, so Disker detects the situation and says so rather than showing a wrong total. Grant
access under **System Settings → Privacy & Security → Full Disk Access**.

macOS keys that grant to code signing identity. Ad-hoc signatures change on every build, which
would revoke the grant each time you rebuild — `Tools/create-signing-identity.sh` creates one
self-signed certificate and `bundle.sh` signs with it, so the grant survives.

## Layout

| Target       | What it is                                                                    |
| ------------ | ----------------------------------------------------------------------------- |
| `DiskerCore` | Scanning, analysis, and Mole integration. No SwiftUI, so it is testable headlessly. |
| `Disker`     | The SwiftUI app.                                                              |
| `diskerctl`  | A headless harness for cross-checking the scanner against `du` and `df`.       |

```sh
swift run diskerctl scan ~/Documents --depth 2
swift run diskerctl volumes
swift run diskerctl recommend
swift run diskerctl mole
```

## Safety

Deleting the wrong thing is the failure mode that matters for a tool like this, so the rules
are explicit:

- Everything removed goes through `FileManager.trashItem` and registers with `UndoManager`. No
  code path calls `unlink`, `removeItem`, or `rm -rf`.
- Installed software is never suggested for deletion — global package-manager roots
  (`/opt/homebrew/lib/node_modules`, `~/.bun/install/global`, nvm/volta/asdf/rbenv/pyenv
  versions, Homebrew's Cellar, and others) are excluded. An early version offered to delete the
  directory containing globally installed CLI tools, which would have uninstalled them.
- Nothing inside an app bundle is offered, so a `node_modules` vendored inside a `.app` is left
  alone.
- Your Mole whitelist at `~/.config/mole/whitelist` is honoured.

Being a parent of protected content is deliberately *not* treated as a reason to stop walking a
directory — conflating the two once pruned the entire home directory from the results.

## Notes on the implementation

A few things that are less obvious than they look:

- **APFS volume groups report identical `st_dev`.** The usual `du -x` trick for staying on one
  filesystem does not work on modern macOS, and following firmlinks double-counts the volume —
  which is how an early build reported 427 GB used on a 228 GB disk. Boundaries come from
  `/usr/share/firmlinks` and `getmntinfo(3)` instead.
- **Hardlinks and APFS clones are counted once**, keyed on `(device, fileID)` and tracked only
  for entries with a link count above one.
- **Mole needs a pty, not a pipe** — it checks `isatty` and will not prompt otherwise. Disker
  runs it under `forkpty(3)` with a VT100 emulator, because Mole redraws in place and simply
  stripping ANSI escapes stacks every frame on top of the last.
- **Children are given default signal dispositions before `exec`.** launchd starts GUI apps
  with `SIGTERM` set to `SIG_IGN`, and an ignored disposition survives `execve`. Inheriting it
  made `mole clean` stall for exactly 300 seconds mid-run and left orphaned processes that no
  `SIGTERM` could reach.

## Status

Early but working end to end: scanning, the chart, recommendations, in-app deletion with undo,
and the full Mole configuration and run flow. Treemap view, search, and duplicate detection are
not implemented.

No license file yet, so default copyright applies.
