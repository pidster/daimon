# Design

## Overview

```
┌────────────┐   prompt    ┌──────────────────┐  respond/stream  ┌──────────────────────┐
│ daimon CLI │ ──────────▶ │ DaimonCore.Agent │ ───────────────▶ │ LanguageModelSession │
│ (ArgParser)│ ◀────────── │                  │ ◀─────────────── │  (FoundationModels)  │
└────────────┘   text      └──────────────────┘                  └──────────┬───────────┘
                                   │ tools: [any Tool]                      │ tool call
                                   ▼                                        ▼
                            ┌──────────────┐        call(arguments:)  ┌───────────┐
                            │ ToolRegistry │ ───────────────────────▶ │ Tool impl │
                            └──────────────┘                          └───────────┘
```

The framework owns the agent loop. When the model emits a tool call, `LanguageModelSession` decodes the
arguments into the tool's `@Generable` `Arguments` type, invokes `call(arguments:)`, appends the result to the
transcript, and continues generation. `Agent` therefore contains no loop of its own; it only guards
availability and shapes the API.

## Repository layout

| Path | Contents |
| --- | --- |
| `harness/` | Swift package: the `daimon` binary and `DaimonCore` |
| `tools/` | Cargo workspace: one crate per Rust tool binary |
| `docs/` | This documentation and the ADRs |
| `scripts/check` | The quality gate for both toolchains |

## Targets

| Target | Kind | Responsibility |
| --- | --- | --- |
| `DaimonCore` | library | `Agent`, `ToolRegistry`, `CommandRunner`, tool implementations, typed errors. All model-facing logic lives here. |
| `DaimonMCP` | library | `DaimonServer` and `ToolCatalog`: exposes daimon over MCP. Depends on `DaimonCore` and the official MCP Swift SDK. |
| `daimon` | executable | Argument parsing and stdin/stdout only. Subcommands `respond` (default), `chat`, `tools`, `logs`, `doctor`, `mcp`. Session set-up is `Session.begin` in `DaimonCore`. |
| `DaimonCoreTests`, `DaimonMCPTests` | tests | swift-testing suites for model-independent logic. |

## Components

### `ModelSelection` and `ResolvedModel`

`ModelSelection` names the model (`system` or `private-cloud`); `resolve()` checks
availability and returns a `ResolvedModel`, which erases the concrete `LanguageModel` behind session
makers and an optional token counter. See [ADR 0013](decisions/0013-model-selection.md).

### `Agent`

Owns one `LanguageModelSession` at a time, created by a `ResolvedModel`, whose `resolve()` checks
availability and throws `ModelSelection.Failure.unavailable` rather than letting the first request fail
obscurely. An agent can also start from a saved `Transcript`.

- `respond(to:)` returns a `Reply`: the text and whether the turn was condensed.
- `stream(_:onDelta:)` invokes a callback with each new fragment and returns the same `Reply`. Snapshots
  are cumulative; if a retry after mid-stream overflow starts an answer that does not continue the text
  already shown, a newline separates the two. It is a callback
  rather than an `AsyncSequence` for a concurrency reason recorded in
  [ADR 0003](decisions/0003-callback-streaming.md).
- On context overflow the `ContextPolicy` (default: keep the last four turns) rebuilds the session from a
  condensed transcript and retries once; `condensations` counts recoveries. See
  [context-management.md](context-management.md) and [ADR 0008](decisions/0008-context-condensation.md).
- `transcript`, `contextTokens()`, and `reset()` support saving, budgeting, and starting over.

### Risk classification and approval

`ApprovalGate` (an actor, one per conversation) takes an `ApprovalThreshold` (a level, or `never`) and runs a `RiskClassifier` (`CompositeRiskClassifier` over
`RuleRiskClassifier` and `ModelRiskClassifier`) and, at or above the configured threshold, asks an
`Approver` (`TerminalApprover`, `DenyingApprover`, `AutoApprover`, or the MCP `ElicitationApprover`).
`CommandRunner` consults the gate after the policy check. See [approval.md](approval.md) and
[ADR 0011](decisions/0011-risk-classifier-and-approval.md).

### Audit and diagnostics

`AuditLog` records `AuditEvent`s for one session through an `AuditSink` (`FileAuditSink` with rotation,
`MemoryAuditSink` for tests). `AuditedTool` wraps every registered tool; `Agent`, `CommandRunner`, and
`DaimonServer` record at their boundaries; the CLI records session start and end. `Diagnostics` wraps
`os.Logger` per category with optional stderr mirroring. See [logging.md](logging.md) and
[ADR 0010](decisions/0010-audit-and-diagnostic-logging.md).

### `Session` and `Conversation`

`Session.begin` is the one place an entry point's flags become a running configuration: it loads
`config.json`, applies `--instructions`, `--model`, and `--unsafe`, checks `--tool` names, opens the
audit log and the `ApprovalStore`, creates the `SessionApprovals` set and the risk classifier, and
records `session.start` with the same fields for `respond`, `chat`, and `mcp`. Anything the user should
see about the set-up (the `--unsafe` warning, the off-device model note) comes back as `notes` for the
face to print; library code never writes to stderr.

What a session builds from its config is injected through `Session.Dependencies`: `live` makes the
on-device classifier when `approval.useModel` is set and appends to the audit file; `testing()` is
rules only with a memory sink. Every unit test passes `testing()`, which is how "tests never need the
model" holds for sessions as well as for gates.

A `Conversation` is one gate plus the tools wired to it, built by one function for every face of daimon.
The approver is the one thing that differs between faces, so it is given when a conversation is opened,
not when the session begins; a `--yes` request replaces it with `AutoApprover` inside the core, so the
flag means the same everywhere. The three faces are overlays on this core:

| Face | How it opens its conversation |
| --- | --- |
| `respond` | `session.openAgent(approver:)` with a denying approver that explains `--yes` and `chat` |
| `chat` | `session.openAgent(approver:transcript:)` with the terminal approver, resumable |
| `mcp` | `session.conversation(id:approver:…)` per `thread_id` with the elicitation approver, its own audit session (recording its own `session.start`), gate, tools, and optional instruction, tool, and model overrides; the server keeps the thread, gate, and audit log together as one `OpenThread` in the `ThreadStore`, so they are created and dropped together |

Every conversation of a session shares its config, `ApprovalStore`, and `SessionApprovals`, so a
"this project" answer on one MCP thread is written once and a "this session" answer covers every thread.
The MCP tests build real sessions over a scratch home and check that two threads share one store.

### Home, config, transcripts

`Home` resolves `$DAIMON_HOME` or `~/.daimon` and lays out `config.json`, `logs/`, and `transcripts/`.
`Config` is optional JSON (instructions, `run_command` limits, MCP thread capacity) with defaults applied by
`resolved`. `TranscriptStore` saves and loads transcripts as `<name>.json`. Commands that write (audit log,
transcripts, the doctor's write probe) call `Home.ensure()`; `tools` and `logs` never create the directory.

### `ToolRegistry`

A static list, `all`, is the single source of truth for what the model can see. `select(_:)` resolves names
from the CLI and reports unknown ones so the CLI can fail before touching the model.

### Tools

Each tool is a `struct` conforming to `FoundationModels.Tool` under `harness/Sources/DaimonCore/Tools/`:

- `name` is the identifier the model uses; keep it `snake_case` and stable.
- `description` is prompt text; write it for the model, not for humans.
- `Arguments` is `@Generable`; use `@Guide` on each property to constrain what the model produces.
- `call(arguments:)` does the work. Keep the formatting logic in a `static` helper so it is testable without the
  model (see `CurrentDateTool.format`).

`CurrentDateTool` is the reference implementation: the on-device model has no clock, so this is the smallest
tool that changes an answer.

`ReadFileTool` pages a text file: `FileReader` streams the file in chunks through a `LineScanner`, skips to
the requested line, and stops when the page or its byte budget is full, so cost is bounded by the page, not
the file. The rendering ends with an offset hint the model follows to continue.

`RunCommandTool` is the generic exec tool. It delegates to `CommandRunner`, which checks the
`CommandPolicy` patterns, consults `ApprovalGate` (rules plus on-device model classifier, ask at
`moderate` and above through an `Approver` per entry point), then spawns `/bin/sh -c` in its own process
group (`posix_spawn`) under `sandbox-exec` with a profile rooted at the launch directory, captures stdout
and stderr separately, kills the whole group on timeout, and keeps only the tail of each stream. The
rendering (`Outcome.rendered`) is what the model sees; policy denials and refusals are rendered too rather
than thrown. See [ADR 0009](decisions/0009-command-policy-and-sandbox.md).

### MCP server

`DaimonMCP.DaimonServer` serves stdio MCP (`daimon mcp`). It advertises `respond` and `close_thread` from
`ToolCatalog`, whose JSON Schemas and descriptions are the contract other harnesses see; daimon's own tools
are reachable only through `respond`, and are described to clients by the `daimon://tools` resources,
generated from `ToolRegistry.descriptions` (schema from each tool's `GenerationSchema`, limits and example
prompt from the tool's own `DaimonTool` conformance, so a changed default shows up in the catalogue).
The request types decode and validate arguments as pure, testable values; see
[ADR 0006](decisions/0006-mcp-server-over-stdio.md).

`respond` runs on a conversation thread. `ThreadStore` is an actor keeping threads by id with LRU eviction;
`ConversationThread` is an actor owning one `Agent`, so calls on a thread serialise while threads run
concurrently. Results carry `structuredContent.thread_id`; see
[ADR 0007](decisions/0007-conversation-threads.md).

```
MCP client ──stdio──▶ DaimonServer ──respond(thread_id)──▶ ThreadStore ──▶ ConversationThread ──▶ Agent ──▶ session ──▶ tools
                                   ──close_thread──▶ ThreadStore
```

### CLI

`daimon` mirrors `fm respond` where semantics match: positional prompt or stdin, `--instructions`,
`--[no-]stream`, repeatable `--tool`. `daimon chat` is a line-oriented REPL with slash commands parsed by
`ChatInput` (`/help`, `/tools`, `/tokens`, `/save`, `/new`, `/quit`), `--resume <name>`, and `--save <name>`.
`daimon tools` lists the registry. `daimon mcp` serves MCP on stdio. Instructions default to `config.json`.
Exit codes follow swift-argument-parser conventions (64 for usage errors).

## Error handling

Errors are typed enums conforming to `Error` and `CustomStringConvertible`. Library code never prints or calls
`fatalError`; the CLI is the only place that renders errors to stderr.

## Concurrency

Swift 6 strict concurrency is enabled. `LanguageModelSession` is not `Sendable`, so `Agent` is a plain
`final class` used from one task at a time, and its async methods are `nonisolated(nonsending)` so they run
in the caller's isolation. That is what lets `ConversationThread` (an actor) own an `Agent`. Do not move
session work into detached tasks.

## Extension points

- New in-process tool: add a file under `Tools/`, append to `ToolRegistry.all`, add a test for its pure helper.
- New Rust tool binary: `cargo new --bin` under `tools/`, list it in the workspace, then either let the model
  reach it through `run_command` or give it a dedicated Swift `Tool` whose description tells the model when to
  use it.
- New MCP tool: add a `Tool` to `ToolCatalog`, a request type, and a case in `DaimonServer.call`.
- Thread persistence or context management: extend `ConversationThread`; record the choice in an ADR.
- Session persistence (transcript save/resume, as `fm` does with `~/.fm/sessions/`) would live in `Agent`.
- Structured output (`fm respond --schema`) would be a `respond(to:generating:)` overload on `Agent`.
