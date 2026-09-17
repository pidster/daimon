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
| `daimon` | executable | Argument parsing and stdin/stdout only. Subcommands `respond` (default), `tools`, `mcp`. |
| `DaimonCoreTests`, `DaimonMCPTests` | tests | swift-testing suites for model-independent logic. |

## Components

### `Agent`

Wraps exactly one `LanguageModelSession`. Construction checks `SystemLanguageModel.default.availability` and
throws `AgentError.modelUnavailable(reason)` rather than letting the first request fail obscurely.

- `respond(to:)` returns the complete reply.
- `stream(_:onDelta:)` invokes a callback with each new fragment and returns the final text. It is a callback
  rather than an `AsyncSequence` for a concurrency reason recorded in
  [ADR 0003](decisions/0003-callback-streaming.md).

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

`RunCommandTool` is the generic exec tool. It delegates to `CommandRunner`, which runs `/bin/sh -c` with a
timeout, captures stdout and stderr separately through pipe readability handlers into `Mutex`-guarded
buffers, kills on timeout via the pid (SIGTERM, then SIGKILL), and keeps only the tail of each stream. The
rendering (`Outcome.rendered`) is what the model sees. There is no sandbox; see
[ADR 0005](decisions/0005-tools-as-plain-binaries.md).

### MCP server

`DaimonMCP.DaimonServer` serves stdio MCP (`daimon mcp`). It advertises `respond` and `run_command` from
`ToolCatalog`, whose JSON Schemas and descriptions are the contract other harnesses see. `RespondRequest` and
`RunCommandRequest` decode and validate arguments as pure, testable values. `respond` builds a fresh `Agent`
per call; see [ADR 0006](decisions/0006-mcp-server-over-stdio.md).

```
MCP client ──stdio──▶ DaimonServer ──respond──▶ Agent ──▶ LanguageModelSession ──▶ tools (run_command, ...)
                                   ──run_command──▶ CommandRunner
```

### CLI

`daimon` mirrors `fm respond` where semantics match: positional prompt or stdin, `--instructions`,
`--[no-]stream`, repeatable `--tool`. `daimon tools` lists the registry. `daimon mcp` serves MCP on stdio.
Exit codes follow swift-argument-parser conventions (64 for usage errors).

## Error handling

Errors are typed enums conforming to `Error` and `CustomStringConvertible`. Library code never prints or calls
`fatalError`; the CLI is the only place that renders errors to stderr.

## Concurrency

Swift 6 strict concurrency is enabled. `LanguageModelSession` is not `Sendable`, so `Agent` is a plain
`final class` used from one task at a time. Do not move session work into detached tasks.

## Extension points

- New in-process tool: add a file under `Tools/`, append to `ToolRegistry.all`, add a test for its pure helper.
- New Rust tool binary: `cargo new --bin` under `tools/`, list it in the workspace, then either let the model
  reach it through `run_command` or give it a dedicated Swift `Tool` whose description tells the model when to
  use it.
- New MCP tool: add a `Tool` to `ToolCatalog`, a request type, and a case in `DaimonServer.call`.
- Session persistence (transcript save/resume, as `fm` does with `~/.fm/sessions/`) would live in `Agent`.
- Structured output (`fm respond --schema`) would be a `respond(to:generating:)` overload on `Agent`.
