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
| `daimon` | executable | Argument parsing and stdin/stdout only. Subcommands `respond` (default), `chat`, `tools`, `mcp`. |
| `DaimonCoreTests`, `DaimonMCPTests` | tests | swift-testing suites for model-independent logic. |

## Components

### `Agent`

Owns one `LanguageModelSession` at a time. Construction checks `SystemLanguageModel.default.availability` and
throws `AgentError.modelUnavailable(reason)` rather than letting the first request fail obscurely. An agent
can also start from a saved `Transcript`.

- `respond(to:)` returns the complete reply.
- `stream(_:onDelta:)` invokes a callback with each new fragment and returns the final text. It is a callback
  rather than an `AsyncSequence` for a concurrency reason recorded in
  [ADR 0003](decisions/0003-callback-streaming.md).
- On context overflow the `ContextPolicy` (default: keep the last four turns) rebuilds the session from a
  condensed transcript and retries once; `condensations` counts recoveries. See
  [context-management.md](context-management.md) and [ADR 0008](decisions/0008-context-condensation.md).
- `transcript`, `contextTokens()`, and `reset()` support saving, budgeting, and starting over.

### Home, config, transcripts

`Home` resolves `$DAIMON_HOME` or `~/.daimon` and lays out `config.json`, `logs/`, and `transcripts/`.
`Config` is optional JSON (instructions, `run_command` limits, MCP thread capacity) with defaults applied by
`resolved`. `TranscriptStore` saves and loads transcripts as `<name>.json`. Read-only commands never create
the directory; `chat` calls `Home.ensure()`.

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
`CommandPolicy` patterns, runs `/bin/sh -c` (under `sandbox-exec` with a generated Seatbelt profile when
the sandbox is enabled) with a timeout, captures stdout and stderr separately through pipe readability
handlers into `Mutex`-guarded buffers, kills on timeout via the pid (SIGTERM, then SIGKILL), and keeps only
the tail of each stream. The rendering (`Outcome.rendered`) is what the model sees; policy denials are
rendered too rather than thrown. See [ADR 0009](decisions/0009-command-policy-and-sandbox.md).

### MCP server

`DaimonMCP.DaimonServer` serves stdio MCP (`daimon mcp`). It advertises `respond`, `run_command`, and
`close_thread` from `ToolCatalog`, whose JSON Schemas and descriptions are the contract other harnesses see.
The request types decode and validate arguments as pure, testable values; see
[ADR 0006](decisions/0006-mcp-server-over-stdio.md).

`respond` runs on a conversation thread. `ThreadStore` is an actor keeping threads by id with LRU eviction;
`ConversationThread` is an actor owning one `Agent`, so calls on a thread serialise while threads run
concurrently. Results carry `structuredContent.thread_id`; see
[ADR 0007](decisions/0007-conversation-threads.md).

```
MCP client ──stdio──▶ DaimonServer ──respond(thread_id)──▶ ThreadStore ──▶ ConversationThread ──▶ Agent ──▶ session ──▶ tools
                                   ──run_command──▶ CommandRunner
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
