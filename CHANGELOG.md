# Changelog

## Unreleased

### Scanning is roughly 5× faster

- Traversal now runs on a pool of workers sharing one queue of directories, instead of fanning
  out only across the root's immediate children. The old shape made a scan take as long as its
  single largest subtree, which on a real disk means one thread walking most of the volume while
  the others idle: 31s at 27% CPU, about one core of eight. The same volume now scans in ~9s.
- Fixing it by calling `concurrentPerform` at every level does not work — nested regions get no
  extra threads once the outer one has claimed the pool, and run on the calling thread instead.
  Recorded in `docs/ARCHITECTURE.md` so it is not retried.
- `workerCount` now does something. It was declared, defaulted, and never read.

### Correctness

- Interrupted (`EINTR`) directory opens are retried instead of being reported as unreadable.
  They were being counted as permission failures, which both dropped those directories from the
  total and inflated the "could not be read" warning. Only visible under concurrency: 217
  unreadable directories with one worker versus 227 with sixteen.
- A negative `getattrlistbulk` return is no longer treated as the end of a directory, which
  would have silently truncated a listing part-way through.
- New tests assert that scan results do not depend on the worker count, and that a deeply
  nested chain finishes rather than stalling.

## v1 — 2026-07-31

First release.

### Scanning

- Full-volume scan built on `getattrlistbulk(2)`, reporting bytes on disk rather than logical
  size, so sparse and APFS-compressed files are not overstated.
- Volume boundaries come from `/usr/share/firmlinks` and `getmntinfo(3)`. Members of an APFS
  volume group report the same `st_dev`, so the usual "stay on one device" check does not
  work — an early build followed firmlinks and reported 427 GB used on a 228 GB disk.
- Hardlinks and APFS clones are counted once, keyed on `(device, fileID)`.
- Unreadable directories are counted and surfaced rather than silently skipped, so a scan
  without Full Disk Access is reported as a lower bound instead of a wrong total.
- Scans are cached, so reopening the app shows the previous result immediately.

### Interface

- Liquid Glass throughout, adapting to light and dark.
- Interactive sunburst: click to drill in, breadcrumb to go back, inspector showing the
  largest items under the selected node.
- Separate views for Storage Overview, Recommendations, and Mole, with a collapsible
  inspector.
- App icon follows the system appearance.

### Cleanup

- Recommendations tiered by how safe they are, never acted on automatically.
- Deletion goes through the Trash and registers with `UndoManager`. No code path calls
  `unlink`, `removeItem`, or `rm -rf`.
- Installed software is never suggested: global package-manager roots, anything inside an app
  bundle, and paths in your Mole whitelist are all excluded.

### Mole

- Full configuration UI for all five operations, dry run or real, rather than only a preview.
- Runs in-app under a pseudo-terminal with a VT100 emulator, so Mole's prompts — including
  sudo — work without leaving the window.
- Scrollback retained, so output longer than one screen stays readable.
- Stop escalates from Ctrl-C to `SIGTERM` to `SIGKILL` rather than assuming the first request
  is honoured.

### Notable fixes during development

- **Mole stalled for exactly 300 seconds mid-run.** launchd starts GUI apps with `SIGTERM` set
  to `SIG_IGN`, and an ignored disposition survives `execve`. Mole kills its own timeout
  watchdog with `SIGTERM` and then waits on it, so inheriting the ignore made that wait run to
  completion — output stopped dead after "Cloud & Office" and the window looked frozen.
  Measured 375s before, 70–87s after. The same inheritance left orphaned processes that no
  `SIGTERM` could reach.
- **The terminal could not be scrolled.** The key-catching overlay covered the transcript, so
  the window handed it every mouse event first, and `NSView` forwards the wheel up the
  responder chain rather than across to the scroll view beside it.
- **Recommendations pegged the CPU** at 70–90% and 3 GB of memory, from a computed property
  recalculated per row per render. Now 0% idle and about 25 MB.

### Known limitations

- Apple Silicon only.
- Ad-hoc signed, not notarised, so the first launch needs a right-click → Open.
- No treemap view, search, or duplicate detection.
