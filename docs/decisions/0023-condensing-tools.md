# ADR 0023: Condensing tools are separate MCP tools, starting with `triage`

Date: 2026-09-20. Status: accepted. Amends [ADR 0006](0006-mcp-server-over-stdio.md).

## Context

wisp's offer to another harness (`docs/objective.md`) is work done locally that the harness would
otherwise do with its own tokens on a remote model: reading, condensing, classifying, extracting over
local data, so the caller's model never ingests the raw material. `respond` can be prompted into any
of this, but a caller then has to coax a 4k-token model through paging and prompting itself, and the
result is prose. Build and test output is the case a coding harness meets most: tens of kilobytes of
which a handful of lines matter.

Two shapes were open: a `task` argument on `respond`, or separate tools. And a question of principle:
ADR 0006 removed the direct `run_command` MCP tool so that every command carries a model turn's audit
trail and wisp is not a remote shell. Triage must run the build to see its output.

## Decision

- `respond` stays general purpose. Each condensing task is its own MCP tool with a fixed contract,
  measured by the eval harness, and described to the caller in `docs/mcp.md`.
- The first is `triage`: a command to run or a file to read, in; a capped list of `{kind, location,
  message}` findings, out. `Triage` (`WispCore/Condense`) captures the output whole up to 1 MiB,
  cuts it into 4 KiB chunks at line ends, judges each chunk in a fresh tool-less turn with a schema
  (ADR 0022) on a conversation of its own (`triage-<id>`, audited start to end), and merges the lists
  with duplicates dropped and a cap. The chunk prompt and the schema are fixed in code, not supplied by
  the caller.
- A condensing tool may run a command itself, through `CommandRunner` with the conversation's gate and
  audit, so the same policy, classifier, approval, sandbox, and `command.outcome` event apply as when
  the model chooses the command. This amends ADR 0006: the reason for removing the direct tool was
  that a remote shell returns raw output; a condensing tool returns none of it, and what it does with
  the output is audited turn by turn under the triage session.
- Reading a file clears the gate as `read_file` does.

## Consequences

- A caller spends one tool call and reads a few hundred bytes instead of a log. The receipt of what
  happened is the triage session in the audit log, reachable as `wisp://audit/triage-<id>`.
- Measured on 2026-09-20 with the system model (`scripts/check eval`, `TriageEvalTests`): 7 of 7
  expected failures found across four abridged fixtures (swift build, swift test, cargo test, pytest),
  no spurious findings. The model names a failing test by its assertion's `file:line` rather than the
  test name; the eval accepts either. Real logs are longer and noisier than the fixtures; the eval floor
  is three quarters recall.
- Cost is one model turn per chunk, sequential: about 2 s per 4 KiB on this Mac, so a 100 KiB log is
  under a minute. A deterministic pre-pass for known formats would cut both time and misses; recorded in
  the backlog with the other condensing tools (summarise, ask over files, extract).
- Tests without the model: chunking, parsing, merging, capture through a real runner and a denying
  gate (`TriageTests`), argument decoding, and the tool over the wire with a scripted judge.
