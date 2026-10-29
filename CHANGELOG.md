# Changelog

## v1.9 — 2026-10-29

### Debloat macOS

- Disker can now turn off Apple Intelligence and delete its models, which take 6–7 GB on a
  typical Mac, along with Mac Analytics, personalized ads, Siri and search data sharing, the
  pop-ups and a long list of Finder, Dock and typing settings. It is
  [RemoveMacAI](https://github.com/omlahore/RemoveMacAI), built in, in a window of its own.
- Nothing changes until you have reviewed the list and clicked Apply, and every change can be
  undone, singly or all at once. Locked settings go in one configuration profile that you
  approve in System Settings; removing the profile undoes them. System Integrity Protection
  stays on and nothing under `/System` is modified.
- The sidebar shows how much space the models take, with a row that opens the window.
  Recommendations offers the same as its first suggestion, and Scan > Debloat macOS
  (⇧⌘D) opens it from the keyboard.
- The window's title names the RemoveMacAI release inside and its date, so it is plain which
  copy you are running.
- One fix of Disker's own on top of RemoveMacAI 1.2.0-beta.1: its review list could leave
  out a half-applied setting you had switched off, which Apply then undid anyway. The review
  now lists it.

### Updates

- Apple changes what RemoveMacAI relies on with each macOS update, and RemoveMacAI ships fixes
  every few days. Disker now takes those in daily, checked first by RemoveMacAI's own
  self-test, and a fix reaches you in the next Disker release.
- So that you hear about that release, Disker asks GitHub for the latest version when it
  opens and shows a card in the sidebar when there is a newer one. It sends nothing but the
  request, never offers a beta, and can be turned off in Settings. It is the only network
  request Disker makes.

## v1.8 — 2026-09-20

### macOS 27

- A blurred band ran across the top of the chart, from the sidebar to the far edge of the
  window, with the breadcrumb and the legend smeared into it. That band is a toolbar's scroll
  edge effect, the blur macOS lays over whatever scrolls beneath it. macOS 26 only drew one
  where something actually scrolled, so the chart never had one; 27 draws it over the column
  whether or not there is a scroll view to attach it to. The window now turns it off for the
  column holding the chart, and the breadcrumb and legend are legible again.
- The sidebar and the inspector now run the full height of the window, flush to its edges,
  with the traffic lights sitting on the sidebar. That is what Finder, System Settings and the
  App Store do on macOS 27. They used to be inset panels floating over the content, rounded on
  all four corners, which is what macOS 26 drew and still draws.
- The 8pt gap that used to hold the inspector clear of the window edge is gone on 27. It
  existed to balance an inset the system applied to one side of a floating panel, and beside a
  flush column it read as a strip of bare window.
- Running on macOS 26 is unchanged. Every one of these is chosen at launch from the version
  actually running, so the two look the way their own version intends.

### Superseded versions, and a few things inside bundles

- Some folders are only dead once you look at their siblings. A browser extension unpacked
  into `13.38.2.0_0` means nothing on its own; it means something next to `13.39.0.0_0`, where
  only the highest version is ever loaded. Suggestions can now read a whole set of siblings and
  offer the ones that have been superseded, keeping the newest.
- This covers Chromium extension versions, per-version Gradle caches, superseded app builds,
  older Android build-tools and platforms, and Arc's snapshots beyond the newest three.
- Two rules keep it honest. A set of one yields nothing, so the only copy of anything is never
  offered. And a single sibling that cannot be parsed silences the whole set rather than
  letting a guess through.
- Version components compare as numbers rather than as text, so `10` sorts above `9`, and
  Android platforms order by API level rather than by the name of their directory.
- A parent folder named `Extensions` is no longer enough on its own. The rule now wants the
  whole Chromium profile shape around it, because `~/project/Extensions/widget/{1.0,2.0}` is
  somebody's own versioned folder and the old reading offered `1.0` as safe to delete.
- Disker can now see inside a bundle, in exactly one place and only for names written down in
  advance: Logic's freeze files, and the render files a Final Cut library accumulates, which
  run to hundreds of gigabytes. Nothing else inside any bundle is reachable by any rule, and a
  test pins that. Re-rendering is the cost of being wrong here, so these are offered for review
  rather than as safe.

## v1.7 — 2026-08-23

### One row for many of the same thing

- A real developer's disk turns up the same artefact over and over. This machine had 146
  `node_modules`, 16 virtual environments and 677 `__pycache__` directories, one row each, and
  the list ran past 1,300 entries. No single row was worth acting on, and everything that was
  got buried under them.
- Suggestions now carry a family, and three or more of a family collapse into one row: "146
  node_modules across 146 projects, 3.13 GB". Click it to see every member, largest first,
  each still actionable on its own. The same list is now about a dozen rows.
- Groups sort by their total rather than by their largest member, so twelve 400 MB folders
  outrank one 1 GB folder. That ordering is the whole point of grouping: it puts the figure
  that matters at the top.
- Acting on a group moves every member to the Trash in one step, and one ⌘Z brings them all
  back. Fifteen separate undo entries would have meant fifteen presses to reverse one click.
- Three is the threshold, not two. Opening a group costs a click, so collapsing two rows into
  one that hides two saves nothing.
- The Trash never joins a group. Acting on a group acts on every member at once, and emptying
  is the one action with no undo behind it.
- `.venv` and `venv` share a family, so four environments make one group instead of two groups
  of one. Families are a property of the list rather than of software development, so the same
  mechanism will carry the caches a photographer or a video editor accumulates once those rules
  exist.

## v1.6 — 2026-08-23

### Emptying the Trash

- "Empty the Trash" failed every time you clicked it. It said "Trash couldn't be moved to the
  trash", which is exactly what it was trying to do. Every deletion in Disker goes through
  `FileManager.trashItem`, and that call refuses to put the Trash inside itself. Emptying acts
  on a different target, the contents of the folder rather than the folder, so it is now
  written as its own operation.
- Emptying is the only irreversible thing Disker does. It confirms first, says the items are
  deleted permanently, and registers no undo. It also clears the undo stack, because every
  entry in that stack restores a file *from* the Trash and emptying destroys all of them at
  once.
- Only a real per-account Trash qualifies. The old rule matched any folder named `.Trash`
  anywhere on the volume: a checked-in test fixture, a synced folder, a `.Trash` inside a
  mounted disk image. Each would have lost its contents on the strength of the name.
- When some items are locked and the empty is partial, the row and the chart stay as they
  were. The row is the only way to retry what is left, and removing it would report space as
  reclaimed while it is still on disk.

### The hub selects the folder you are looking at

- Clicking the middle of the chart used to step back out, which made it the one control whose
  click undid the gesture that reached it. It now selects the folder being charted. Nothing
  else could reach that folder, because it has no wedge of its own, so Show in Finder and Move
  to Trash only ever appeared for things inside it. The breadcrumb still goes up, and so does
  ⌘↑.
- Hover the hub and it tells you what the click does, in the line that otherwise carries the
  percentage. The pointer turns into a hand. A circle of figures gives no sign that it is a
  control at all.

### The legend describes the colours on screen

- The legend classified the charted folder's direct children, which works only while those
  children are where the colours come from. Drill into `Users` and every child is
  `Users/<account>`, so the legend collapsed to one entry reading "Users" above a chart drawn
  in five colours it never mentioned.
- It now rolls totals up from the same subtree the chart draws. Each folder's bytes count once,
  at the depth where its category is decided, so the numbers still add up to the folder's own
  size. The walk stops where classification can no longer change, so it never crawls the whole
  volume to build a legend.

### The panels line up

- The inspector is a split-view item instead of SwiftUI's `.inspector`. That modifier's panel
  was clipped by the column it lived in, leaving three different corners on one panel: rounded
  across the top, square at the bottom left, cut to the window's much larger radius at the
  bottom right. The sidebar beside it was rounded evenly on all four.
- Its outer edge now sits as far off the window as the sidebar's. macOS insets an inset
  sidebar's *leading* edge, which is the outer edge on the left and the inner one on the right,
  so the trailing panel ended up flush against the window. An empty 8pt split item supplies the
  gap, which leaves the system's radius and specular edge alone. Insetting the panel's own
  contents does not work, because the system paints across the item's full width and leaves a
  step below the corner.
- The buttons in the Mole sheet no longer fight its corners. A 5pt corner sat 12pt inside a
  26pt one, and the gap between the two pinched shut diagonally. They are capsules now, which
  is where Apple's concentricity rule lands at this size, and the header and footer sit 16pt in
  so nothing crowds the arc.

## v1.5 — 2026-08-15

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

- A reaped child's pid is forgotten in the same locked step as the reaping, and every signal
  is delivered while holding that lock. A pid belongs to us only until it is reaped; after
  that the kernel may hand the number to somebody else, and signalling it was not a harmless
  no-op — it went through the process-group lookup, which would have resolved a stranger's
  group and `killpg`ed it. Reachable in ordinary use: let Mole finish, then close the sheet.
  The wait is now done in two steps, `waitid(WNOWAIT)` then `waitpid(WNOHANG)`, so the child
  stays a zombie — still owning its pid, so the number cannot be reused — until the reap and
  the forgetting happen together.
- The pty descriptor lives behind a holder that makes using it and closing it mutually
  exclusive, instead of being passed around as a bare number. `send`, `resize`, and
  `interrupt` copied that number under a lock, released the lock, and only then made their
  syscall — and in that gap the read source's cancel handler could close it. A closed
  descriptor is a harmless `EBADF`, but the kernel reuses the lowest free number, so a
  keystroke could land in an unrelated file. This window was opened by the change below,
  which moved the close from `deinit` to end-of-stream; it is now closed for good.
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
