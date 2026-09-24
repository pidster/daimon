# ADR 0032: Log and JSON condensers are deterministic

Date: 2026-09-23. Status: accepted. Extends [ADR 0023](0023-condensing-tools.md).

## Context

After `triage` and `summarise_diff`, the local material a coding agent most often has to read in bulk is
logs (an app's log, CI output, `log show`), crash reports, and large JSON (an API response, an export,
a JSON Lines file). Each costs a remote model tens of thousands of tokens to read and a few hundred to
act on. The existing condensers judge chunks with the on-device model at about 2 s per 4 KiB; a
megabyte of unified log would take minutes that way, and the small model is not needed to see that the
same message repeated a thousand times.

Measured on this Mac on 2026-09-23: two minutes of `log show` was 14,333 lines and 2.8 MB. Reduced to
templates (timestamp removed; numbers, hex, UUIDs, ids, and `[pid:thread]` replaced) it was 1,972
distinct messages, and the top 30 by severity and count fit in about 10 KB, computed in 1.2 s. A real
`.ips` crash report from `~/Library/Logs/DiagnosticReports` is a JSON header line and a 22 KB JSON body
of which the process, exception, termination, and faulting thread's frames are what a reader needs.

## Decision

- **`condense_log`** (MCP) groups a log's lines by template and ranks the groups by severity, then count,
  with line ranges, first and last timestamps, and one example per group with credentials redacted
  (ADR 0031). Severity comes from the log's own type column when it has one (`log show`'s default
  style's `Error`/`Fault`, its compact style's `E`/`F`), because `Default` lines are full of words like
  "critical"; otherwise from words. In a log whose lines carry timestamps, a line without one continues
  the line before and takes its severity. A `.ips` crash report is recognised and returned as the
  process, version, OS, exception, termination, and the faulting thread's top 12 frames with image
  names. Input up to 8 MiB, the tail beyond.
- **`json_shape`** (MCP) outlines a JSON document, or JSON Lines when the whole does not parse and every
  line does: each key's types, optional keys (present in fewer objects than their parent), array
  lengths, number ranges, and a 40-character string example with credentials and personal data
  redacted and line breaks escaped. Array elements merge into one outline; plain values are listed before
  nested ones so a large subtree cannot push its siblings past the line cap. Input up to 16 MiB, and
  input cut to fit is refused, because a document without its head does not parse.
- **No model.** Both are deterministic and fast. A model's reading of the groups (a headline, a likely
  cause) is the calling agent's job once it has the few kilobytes; it is not added here until a measured
  case shows the on-device model adds something the caller cannot.
- Both capture through the conversation's runner and gate, like `triage`, on conversations `log-<id>` and
  `shape-<id>`, so a command's approval, sandbox, and audit are as for every command.

## Consequences

- A megabyte log costs about a second and returns a few kilobytes; nothing about it needs `scripts/check
  eval`, and the tests cover it fully without the model.
- Template grouping is only as good as the placeholders: a message that embeds a variable word (a user
  name, a path) forms one group per value. The example and line range still point to the lines.
- Other condensers named with these (dependency audit output, profiler exports, flaky tests across
  runs) are left for later; `docs/backlog.md` lists them.

## Amendment, 2026-09-24: the unified log is read in process, and a failing command is flagged

Using `condense_log` from Claude Code showed two gaps. `/usr/bin/log show` cannot run as a wisp command:
it checks whether it is sandboxed and exits with `log: Cannot run while sandboxed`, even under a
Seatbelt profile that allows everything, so no change to wisp's profile could help. The measurement
above was of `log show` output captured outside wisp. `condense_log` now takes `last` (such as `10m`,
at most a day) with optional `process` and `subsystem` filters and reads the unified log in wisp's own
process through `OSLogStore.local()`, which an unsigned binary may open (probed the same day: 26,566
entries from one minute in about a second). The entries are written as `log show` compact-style lines
so their declared type decides severity.

The same session showed the condensers ignoring the command's exit status: `log show`'s one-line refusal
came back as a one-line `info` log, and a failing `git diff` would have read as a clean scan. Every
condensing tool with a command source now returns `exitStatus` and `timedOut`, and its text starts with a
warning and the first line of output when the command failed or timed out.

