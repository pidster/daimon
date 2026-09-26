# 0039: Read known formats exactly, and the model only for the rest

Date: 2026-09-26. Status: accepted. Amends [ADR 0023](0023-condensing-tools.md).

## Context

`triage` sent every 4 KiB chunk of build and test output to the on-device model, which takes seconds per
chunk, though most of that output is in a handful of formats that compilers and test runners print the
same way every time: `file:line:col: error:`, rustc's `error[E…]` with a `-->` line, swift-testing's
`✘ Test … recorded an issue at`, cargo's `test … FAILED`, pytest's `FAILED path::test`. ADR 0023 and the
backlog proposed a deterministic pre-pass for them, measured against the eval fixtures first.

The backlog also named three more condensers from the same family: dependency audits reduced to what
needs action, flaky tests found by comparing runs, and profiles reduced to hot paths. Each has a
machine-readable input (JSON, outcome lines, folded stacks) where a model would add cost and doubt and
nothing else. [ADR 0038](0038-fast-specialised-classifiers.md) set the direction: fast and specialised
wherever a general model is not needed.

## Decision

1. **Triage reads known formats exactly first.** `KnownFailures` scans each chunk with line patterns
   for Swift, clang, and XCTest diagnostics, rustc errors and warnings located by their `-->` line,
   swift-testing issues, cargo test failures and panics, pytest `FAILED` and `ERROR` summary lines, and
   go test's `--- FAIL:`, and recognises the tools' own tallies and section headers. A chunk whose every
   failure-looking line (error, failed, panic, fatal, crash, exception, assertion) is accounted for gets
   no model turn. Any other chunk still goes to the model, and its findings follow the exact ones; a
   model finding at a location the rules already read is dropped, since it only rewords it. The report
   gains `exactChunks`.
2. **`dependency_audit`**: `npm audit --json` (report version 2), `cargo audit --json`, or
   `pip-audit -f json` into one line per advisory (package, version or vulnerable range, severity,
   advisory id, title, the fix), most severe and fixable first, with counts per severity and
   `cargo audit`'s unmaintained and yanked crates as warnings. `cargo audit` gives a CVSS vector, not a
   severity, so the severity is estimated from the vector's base metrics. An audit that exits non-zero
   because it found something is not flagged as a failed command.
3. **`flaky_tests`**: two or more runs, saved files or a command run 2 to 10 times, read into a pass or
   fail per test name (swift-testing, XCTest, cargo test, pytest `-rA` and `-v`, go test `-v`); the
   result lists tests that passed in some runs and failed in others, most often failing first, and
   tests that failed in every run. A command run several times runs in one conversation, so one
   approval covers the repeats.
4. **`hot_paths`**: folded stacks (`frame;frame;frame count`, what stackcollapse, `py-spy -f raw`,
   `cargo flamegraph`, and pprof reduce to) into the functions with the most self time, with their
   total time, and the heaviest stacks, as shares of all samples.
5. None of the three uses a model. Each captures through the same runner, gate, and audit as the other
   condensing tools, and each result is bounded.

## Measured, 2026-09-26

On `TriageEvalTests`' four fixtures (`swift build`, `swift test`, `cargo test`, `pytest`), with the system
model: recall stayed 7/7, and all four chunks were read exactly, so no fixture needed a model turn.
The first run left the pytest chunk to the model because pytest's `==== FAILURES ====` section header
looked like a failure; recognising pytest's section headers made it 4 of 4. The unit tests cover each
format, including one the rules cannot read (a segmentation fault), which goes to the model.

## Consequences

- Triage of output in a known format is exact and costs no model time; the model reads what the rules
  cannot, so an unfamiliar format is no worse than before.
- A new format is a pattern and a test, not a prompt change. A pattern that misreads is a bug with a
  unit test to add, not a probability.
- The formats are the tools' current ones; a change in a tool's output shows up as chunks going back
  to the model, which `exactChunks` makes visible.
