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

## Everything else

Disker has no third-party package dependencies. `Package.swift` declares none; it builds
against the macOS SDK and the Swift standard library only.

The app icons in `Resources/` are original artwork belonging to the project.
