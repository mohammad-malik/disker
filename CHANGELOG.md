# Changelog

## Unreleased

### Drilling into an outer ring no longer loses its way

- Double-clicking a wedge on any ring but the innermost appended only that wedge to the
  drill stack, discarding every folder between it and the chart's root. Since that stack is
  what breadcrumbs, absolute paths, and category colours are all derived from, one
  double-click broke all three at once: the breadcrumb read "Data > mohammadmalik" with
  `Users` missing, the whole home directory turned grey because classification no longer saw
  a path starting with `Users`, and Reveal in Finder, Copy Path, and Move to Trash were
  handed `/System/Volumes/Data/mohammadmalik`, which does not exist.
- The legend under the chart classified on the bare folder name, ignoring where the chart was
  drilled to. Inside a home directory it read `Library` as system-wide `/Library` and filed
  `Documents` under "Other", so its swatches disagreed with the wedges they explain.

### Forking Mole

- The pty's read source is published before it is resumed, and only ever cancelled under the
  lock. It was assigned *after* `resume()`, so for a command that exited immediately the
  end-of-file handler could run while the reference was still nil — the cancel then did
  nothing and left a dispatch source re-arming forever on a stream at permanent end-of-file,
  spinning a global queue for the life of the object. The window was widest for exactly the
  cases that matter: a failed exec, or a command that prints once and exits.
- The descriptor is now owned by that source and closed from its cancel handler, rather than
  in `deinit`. Closing a descriptor a dispatch source is still watching is undefined, and
  tying it to deallocation meant a finished session held its pty for as long as the window
  lived. Measured: 24 short-lived terminals leaked exactly 24 descriptors before, 0 after.

- The child of `forkpty` no longer allocates before `exec`. It was reading
  `ProcessInfo.processInfo.environment` and calling `strdup` between the fork and the exec,
  where only async-signal-safe calls are permitted: the child gets one thread but inherits
  every lock the others held, including the allocator's, and the thread that would release it
  does not exist there. argv and envp are now built before the fork. No observed failure is
  attributed to this — an A/B of 20 runs each showed no difference — but the app forks Mole
  while SwiftUI, the scanner's workers, and Dispatch all have threads running, and a child
  deadlocked before exec would present as a terminal that opens and stays blank forever.
- Signals are never sent to a process group that is still our own. `forkpty` makes the child a
  session leader, but `setsid` runs in the child, and until it has, `getpgid(child)` reports
  the group it was forked into — ours. A `killpg` in that window would have hit Disker itself
  and every other child of it.
- The pty test suite is serialized. `signal(SIGTERM, SIG_IGN)` is process-wide rather than
  thread-scoped, so tests running in parallel were mutating each other's forked children.
  Measured 10 failures in 20 parallel runs on a busy machine against 0 in 20 serially, with
  each test passing 20 in 20 on its own.

### Breadcrumb

- Right-click any breadcrumb entry for Copy Path and Reveal in Finder; hovering shows the
  full path.
- The path is now a row of chips on a recessed track rather than bare text. It was a control
  whose whole job is to be clicked, with a hit target of 24×14pt for a crumb named "Data" —
  under half the 28pt minimum in both directions. Chips are 28–30pt tall, highlight on hover,
  and the current folder rides on interactive glass.

## v1.1.1 — 2026-08-02

### Mole's preview no longer blocks every launch

- `mole clean --dry-run` takes about 98 seconds — longer than scanning the whole disk — and
  was run on every launch, so "Checking with Mole…" sat there for a minute and a half while
  competing with the scan that had just started. There is no faster way to ask: Mole has no
  JSON form of the preview, `analyze` answers a different question, and `history --json`
  reports past cleanups rather than a forecast.
- The preview is now cached for 24 hours and shown immediately with its age. Mole is re-run
  only when that has gone stale, when you press Refresh, or after an actual cleanup, which
  invalidates it because Mole has just deleted the things it was counting.
- A cached figure stays on screen while a refresh runs, rather than being replaced by a
  spinner for the ~98 seconds it takes.
- Failed parses are not cached, so one transient failure cannot pin "couldn't read Mole's
  output" on screen for a day.

## v1.1 — 2026-08-02

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

### Permissions

- The "N folders could not be read" notice no longer tells you to grant Full Disk Access when
  you already have. It keyed off the unreadable count alone, so granting access changed the
  number but not the advice — and the advice could not have worked, because what stays
  unreadable on a granted scan is root-owned system state (`/private/var/folders`,
  `/private/var/db`, `/private/var/spool` and similar) guarded by Unix permissions rather than
  by TCC. It now says those folders are reserved for macOS, and asks for the grant only when
  asking would achieve something.
- The grant is re-checked when a cached scan is shown, not only when a scan is taken. It was
  set inside the scan path alone, so opening the app to yesterday's cached result described it
  using an optimistic default instead of the current state.
- Granting Full Disk Access is worth doing: on the development machine it was the difference
  between 204.8 GB with 217 unreadable folders and 200.8 GB with ~376.

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
