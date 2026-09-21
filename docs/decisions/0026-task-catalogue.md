# ADR 0026: Eval results ship with the tool catalogue as measurements

Date: 2026-09-20. Status: accepted.

## Context

A calling harness reads `wisp://tools` to learn what the on-device model can do, but nothing there
says how well. The eval harness (`scripts/check eval`) measured the risk classifier and, since ADR
0023, triage, and the numbers lived in commit messages and doc pages by hand. The `edit_file` probe
showed the gap: the tool works, the model's use of it was unmeasured, and a caller had no way to know.

Where the numbers could live: a doc page (stale, unreachable to a client), a file under `~/.wisp`
(not shipped; a fresh install has none), or the binary (shipped with the code that was measured).

## Decision

- A `Measurement` is one eval run of one task on one model: `task`, `tool` when the task is a model
  tool, `model`, `date`, `passed`, `total`, and one sentence of `notes` saying what a pass is.
- Eval tests call `Measurements.report`, which prints the result and, when `WISP_EVAL_RECORD`
  names a file, merges it there by task and model. `scripts/check eval` points that at
  `Resources/measurements.json`, embedded at build time by the same plugin as the system prompt, so a
  binary carries the numbers committed with it and the release preflight (which runs the eval)
  refreshes them.
- The catalogue attaches measurements to each tool by name (`ToolDescription.measurements`, a
  `Measured:` line in the Markdown); `wisp://measurements` lists them all, including tasks that
  are not one tool.
- Eval tests assert floors only; the numbers are reported and recorded. A measurement is described
  as an eval run, never as a certification.

## Consequences

- A caller can branch on `passed/total` for the model it is about to use, and a fresh install reports
  the same numbers the release was cut with.
- The measurements file changes whenever the eval runs; it is committed with the change that moved
  the numbers. Two people running the eval on different Macs will differ slightly; the model and date
  say where a number came from.
- Sets are small (five to forty-five cases) and abridged; they catch regressions, not rare failures.
  Widening them is ordinary work, no ADR.
- Tests without the model: decoding, merging, encoding, and attaching measurements to tools
  (`MeasurementsTests`, `ToolDescriptionsTests`); the resource over the wire.
