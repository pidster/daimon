# ADR 0010: Verbatim JSON Lines audit log plus unified-logging diagnostics

Date: 2026-09-17. Status: accepted.

## Context

A tool-using agent that runs commands needs an audit trail (what was asked, decided, run, returned) and
debuggability. The coming risk classifier and approval flow are only auditable if the plumbing exists first.

## Decision

- Two logs. An append-only JSON Lines **audit log** at `~/.daimon/logs/audit.jsonl`, and **diagnostics**
  through `os.Logger` under one subsystem with a category per component, mirrored to stderr when
  `DAIMON_LOG` is set. The MCP SDK's swift-log is bridged into diagnostics.
- Audit content is **verbatim** (owner's decision): an audit log that cannot be read is not one. The file
  is mode 0600 and rotated by size.
- One envelope for every event (schema, time, version, pid, session, turn, call, kind, details), with
  stable kind names and documented detail fields, so the file is queryable with `jq` and readable by
  `daimon logs`.
- Hooks sit at existing boundaries: `Agent` for turns and condensation, `AuditedTool` around every
  registered tool, `CommandRunner` for policy and outcome, `DaimonServer` for MCP requests and results,
  and the CLI for session start and end. `AuditLog` assigns turn numbers so every event in a turn agrees.
- `AuditSink` is a protocol; tests use an in-memory sink, disabled config uses a null sink.

## Consequences

- Every new tool is audited for free; every new event kind must be added to `docs/logging.md`.
- Writes are synchronous per event. The volume is small (tens of events per turn) so this is fine, and it
  means an event is on disk before the action it describes completes.
- Concurrent daimons append to the same file; `pid` separates them. Lines are written whole.
- Reserved kinds (`classifier.verdict`, `approval.*`) are in place for the classifier.
