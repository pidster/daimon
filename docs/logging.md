# Logging: audit and diagnostics

daimon keeps two logs with different jobs. The **audit log** is the record of what the agent was asked,
what it decided, what it ran, and what came back, written verbatim for the user alone. The **diagnostic
log** is for debugging daimon itself and goes through Apple's unified logging.

## Audit log

Location: `~/.daimon/logs/audit.jsonl` (under `$DAIMON_HOME` when set). JSON Lines, one event per line,
mode `0600`, rotated by size to `audit.1.jsonl` … `audit.N.jsonl`. Every entry point writes to it: `respond`,
`chat`, and `mcp`. It is on by default; `config.json` controls it:

```json
{ "audit": { "enabled": true, "maxFileBytes": 10485760, "keepFiles": 5 } }
```

Content is stored verbatim by decision (prompts, replies, commands, tool output). Treat the file as
sensitive; it is why it is user-only.

### Event envelope

| Field | Meaning |
| --- | --- |
| `schema` | Event schema version, currently 1. |
| `time` | ISO 8601 UTC with milliseconds. |
| `version` | daimon version that wrote it. |
| `pid` | Process id, to separate concurrent daimons sharing a file. |
| `session` | A CLI run, a chat, an MCP server, or an MCP thread (its `thread_id`). |
| `turn` | 1-based turn within the session, present from the first prompt on. |
| `call` | Pairs a `tool.call` with its `tool.result`, or an `mcp.request` with its `mcp.result`. |
| `kind` | One of the kinds below. |
| `details` | Kind-specific fields. |

### Kinds and their details

| Kind | Details | Written by |
| --- | --- | --- |
| `session.start` | `entryPoint` (`respond`, `chat`, `mcp`, `mcp-thread`), `instructions`, `tools`, `model`, `unsafe`, `autoApprove`, `resume` (all entry points record the same fields via `Session.begin`), `reason` (`new`) | CLI, MCP |
| `session.end` | `reason`: `closed` (explicit), `evicted` (least recently used thread dropped at capacity) | CLI, MCP |
| `prompt` | `text` | `Agent` |
| `response` | `text`, `condensed`, `seconds` | `Agent` |
| `tool.call` | `tool`, `arguments` (JSON as the model produced it) | `AuditedTool` |
| `tool.result` | `tool`, `output`, `bytes`, `seconds` | `AuditedTool` |
| `policy.decision` | `command`, `workingDirectory`, `verdict` (`allowed`, `denied` by pattern, `disapproved` by the gate), `reason`, `sandbox`, `network`, `nested`; recorded once, after the directory check, patterns, and approval | `CommandRunner` |
| `command.outcome` | `command`, `exitStatus`, `timedOut`, `truncated`, `stdout`, `stderr`, `seconds` | `CommandRunner` |
| `context.condensation` | `turnsBefore`, `turnsAfter`, `contextSize`, `tokenCount` | `Agent` |
| `mcp.request` | `tool`, `arguments` | `DaimonServer` |
| `mcp.result` | `tool`, `isError`, `text`, `seconds` | `DaimonServer` |
| `error` | `message`, `context` | anywhere |
| `classifier.verdict` | `command` (one simple command), `pattern`, `line` (when the command is part of a longer line), `level`, `reasons`, `sources`, `seconds` | `ApprovalGate` |
| `approval.requested` | `command`, `pattern`, `line`, `level` | `ApprovalGate` |
| `approval.decided` | `command`, `decision` (`approved` with `scope`, `denied`, `timed-out`, `cached` for session, `cached-project`/`cached-always` for persisted), `reason`, `approvalID`, `expiresAt`, `downgradedFrom` when a dangerous command's persisted scope was reduced to session | `ApprovalGate` |

Every tool the model can call is wrapped by `AuditedTool`, so a new tool is audited without doing anything.

### Reading it

`daimon logs` prints one-line summaries, newest last, across rotated files:

```
daimon logs                                   # everything
daimon logs --session 5fd0cf21                # one session
daimon logs --kind tool.call --kind tool.result --tool run_command
daimon logs --last 20 --json | jq .           # raw events
```

A session's events group on `session`; a tool call and its result share `call`. Saved transcripts in
`~/.daimon/transcripts` hold the same conversation in the framework's own format.

### In code

`AuditLog` records events for one session and numbers turns; `AuditSink` is where they go
(`FileAuditSink`, `MemoryAuditSink` for tests, `NullAuditSink` when disabled). Sibling logs for other
sessions share a sink via `log(forSession:)`. Events are `AuditEvent` values; add a `Kind` and document it
here. Tests assert on `MemoryAuditSink.events`.

## Diagnostic log

Every component logs through `Diagnostics.<category>` (`agent`, `tools`, `policy`, `mcp`, `chat`, `audit`)
to unified logging under subsystem `com.pidster.daimon`. The MCP SDK's swift-log output is bridged into the
`mcp` category.

```
log stream --predicate 'subsystem == "com.pidster.daimon"' --level debug
DAIMON_LOG=debug daimon "…"      # also mirror to stderr: debug, info, or error
```

Messages are marked public so they are not redacted. Nothing ever goes to stdout, which stays the MCP
protocol channel.
