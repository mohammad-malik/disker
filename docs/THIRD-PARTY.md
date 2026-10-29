# Third-party software

## Mole

[Mole](https://github.com/tw93/mole) is licensed **GPL-3.0-or-later**.

Disker does not include, bundle, link against, or redistribute any part of Mole. It locates an
existing `mole` on your `PATH` and runs it as a separate process, reading its output over a
pipe or pseudo-terminal. Everything under `Sources/DiskerCore/Mole/` is original Disker code —
a client, an output parser, and a terminal emulator — written against Mole's command-line
interface and printed output, not derived from its source.

Under the FSF's own reading of the GPL, that is the textbook case of two separate programs
rather than one combined work. Their [licensing
FAQ](https://www.gnu.org/licenses/gpl-faq.html#MereAggregation) treats pipes, sockets, and
command-line arguments as "communication mechanisms normally used between two separate
programs", in contrast to linking into a shared address space. So Mole's copyleft does not
reach Disker, and Disker is free to carry its own license.

Two things would change that, and neither is true today:

- **Shipping the `mole` binary inside `Disker.app`.** That would be redistribution of GPL
  software, obliging Disker to satisfy GPL-3 for that copy — including a corresponding-source
  offer — and would make the "separate programs" argument considerably weaker.
- **Vendoring or translating Mole's source** into Disker rather than calling its CLI. That
  would produce a derivative work outright.

If you are contributing, keep the boundary at the process edge. Install Mole with
`brew install mole` rather than bundling it.

This note is a good-faith engineering analysis, not legal advice.

## RemoveMacAI

[RemoveMacAI](https://github.com/omlahore/RemoveMacAI) is licensed **MIT**, and builds on
[pared](https://github.com/4evy/pared), also MIT. Unlike Mole, it *is* included: the Debloat
macOS window is RemoveMacAI's own interface and engine, compiled into Disker.

- `Sources/RemoveMacAIKit/Upstream` and `Sources/UAF` are a copy of a RemoveMacAI release,
  replaced wholesale by `Tools/sync-removemacai.sh` and never edited by hand. The only
  changes are the patches in `Tools/removemacai-patches`, each also meant for upstream.
- MIT asks that its notice travel with every copy. Both licences are in
  `Sources/RemoveMacAIKit/Upstream`, and `bundle.sh` copies them into
  `Disker.app/Contents/Resources/RemoveMacAI` so they ship inside the app as well.

## Everything else

Disker declares no package dependencies. `Package.swift` builds against the macOS SDK and
the Swift standard library, plus the RemoveMacAI copy above.

The app icons in `Resources/` are original artwork belonging to the project.
