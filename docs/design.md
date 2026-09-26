# Design

## Overview

```
┌────────────┐   prompt    ┌──────────────────┐  respond/stream  ┌──────────────────────┐
│ wisp CLI │ ──────────▶ │ WispCore.Agent │ ───────────────▶ │ LanguageModelSession │
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
| `harness/` | Swift package: the `wisp` binary and `WispCore` |
| `tools/` | Cargo workspace: one crate per Rust tool binary |
| `docs/` | This documentation and the ADRs |
| `scripts/check` | The quality gate for both toolchains |

## Targets

| Target | Kind | Responsibility |
| --- | --- | --- |
| `WispCore` | library | All model-facing logic, grouped by folder: `Session/` (session, conversation, agent, model selection, context policy, tool registry and catalogue), `Exec/` (command runner, policy, splitter, regex cache), `Approval/` (gate, classifiers, store, threshold), `Audit/` (events, details, log, turn clock, diagnostics), `Tools/` (the tools, the file reader, and the audit wrapper), `Config/` (config, home, transcripts), `CLI/` (doctor and chat input, here so they are testable), `Support/` (timeout, ids, names). |
| `WispCoreAI` | library | `CoreAIBackend`: models exported to Apple's Core AI format, through the bridge in `apple/coreai-models`. Registered by the executable at launch so `WispCore` never links it. |
| `WispMLX` | library | `MLXBackend`: models in MLX or Hugging Face layout through `mlx-swift-lm`'s bridge, compiled in only under the `MLX` package trait (Metal toolchain); otherwise registered but refusing with the reason. |
| `WispMCP` | library | `WispServer` and `ToolCatalog`: exposes wisp over MCP. Depends on `WispCore` and the official MCP Swift SDK. |
| `wisp` | executable | Argument parsing and stdin/stdout only. Subcommands `respond` (default), `chat`, `tools`, `models`, `logs`, `doctor`, `approvals`, `mcp`. Session set-up is `Session.begin` in `WispCore`. |
| `EmbedSystemPrompt` | build-tool plugin | Embeds `Resources/system-prompt.md` into `WispCore` as a string constant at build time. |
| `WispTestSupport` | library, tests only | `ScriptedModel`: a `LanguageModel` that answers from a script, so the agent, tool loop, and MCP server run in tests with no model. |
| `WispCoreTests`, `WispMCPTests` | tests | swift-testing suites for model-independent logic; `WispServerWireTests` drives the server through a real MCP client on an in-memory transport. |

## Components

### `ModelSelection` and `ResolvedModel`

Local runtimes are `ModelBackend`s in the `ModelBackends` registry, keyed by scheme; `ModelSelection.local`
is spelled `<backend>:<name>` and resolves through the registry. A `ResolvedModel` carries the model's
declared capabilities and their source, and `Conversation.openAgent` refuses a request that needs tool
calling the model did not declare, then records `model.resolved`; see
[ADR 0019](decisions/0019-model-backends.md). Any `LanguageModel` can be wrapped by
`ResolvedModel(selection:custom:)`. `OllamaModel` is the first backend:
its `Executor` maps the transcript onto Ollama's chat API (system, user, assistant with tool calls, tool
messages), sends tool definitions as JSON Schema and an output schema as `format`, and streams chunks back
as `response` and `toolCalls` events with usage at the end. `resolve` checks the server lists the model
(blocking briefly, because agents are created synchronously). The framework's tool loop, streaming,
transcript, and guided generation are unchanged above it. See
[ADR 0016](decisions/0016-local-runtimes-through-an-executor.md).

`ModelSelection` names the model (`system`, `private-cloud`, or `ollama:<name>`); `resolve()` checks
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
`WispServer` record at their boundaries; the CLI records session start and end. `Diagnostics` wraps
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

A `Conversation` is one gate plus the tools wired to it and the `Prompting` the agent starts with, built by
one function for every face of wisp. `Prompting` renders three layers into the framework's instructions:
wisp's own system prompt (the file `Resources/system-prompt.md`, embedded at build time by the
`EmbedSystemPrompt` plugin), the operator's `systemPromptExtension` from config, and the caller's
conversation instructions; see [ADR 0017](decisions/0017-three-layer-instructions.md).
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

### `Introspection`

Read-only views of wisp's own state, built once and rendered three ways: the model's `inspect` tool,
the MCP `wisp://config|status|approvals|audit` resources, and `wisp config` and `wisp logs`. It
holds the home, the effective config, the approval store, and a status closure the `Conversation`
supplies (session id, turn, tools, model, session approvals); the MCP server adds live thread ids and
the standing-approval count to the status resource. Audit reads go through the same file walk `logs`
uses. See [ADR 0018](decisions/0018-introspection.md).

### Home, config, transcripts

`Home` resolves `$WISP_HOME` or `~/.wisp` and lays out `config.json`, `logs/`, and `transcripts/`.
`Config` is optional JSON (system prompt extension, model, `run_command` limits, MCP thread capacity) with defaults applied by
`resolved`. `TranscriptStore` saves and loads transcripts as `<name>.json`. Commands that write (audit log,
transcripts, the doctor's write probe) call `Home.ensure()`; `tools` and `logs` never create the directory.

### `ToolRegistry`

A static list, `all`, is the single source of truth for what the model can see. `select(_:)` resolves names
from the CLI and reports unknown ones so the CLI can fail before touching the model.

### Tools

Each tool is a `struct` conforming to `FoundationModels.Tool` under `harness/Sources/WispCore/Tools/`:

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

`EditFileTool` is its counterpart: `FileWriter` writes, appends, or replaces one exact match, and refuses
any path outside `CommandPolicy.writableRoots`, the list the Seatbelt profile is built from, so the
tool can change no more than a command could. Each edit is cleared by the gate as
`edit_file <mode> <path>` and recorded as `file.write` ([ADR 0024](decisions/0024-edit-file.md)). The
tools do not share one control path: `run_command` passes the policy patterns, the gate, and Seatbelt;
`edit_file` the writable list and the gate; `read_file` the gate's rules only; `inspect` and
`current_date` none. `NotifyTool` posts through the session's `Notifier` (`osascript` with the text in
`argv`), bounded, rate-limited, and audited as `notification`, without the gate
([ADR 0030](decisions/0030-notifications.md)).

`RunCommandTool` is the generic exec tool. It delegates to `CommandRunner`, which checks the
`CommandPolicy` patterns, consults `ApprovalGate` (rules plus on-device model classifier, ask at
`moderate` and above through an `Approver` per entry point), then spawns `/bin/sh -c` in its own process
group (`posix_spawn`) under `sandbox-exec` with a profile rooted at the launch directory, captures stdout
and stderr separately, kills the whole group on timeout, and keeps only the tail of each stream. The
rendering (`Outcome.rendered`) is what the model sees; policy denials and refusals are rendered too rather
than thrown. See [ADR 0009](decisions/0009-command-policy-and-sandbox.md).

### MCP server

`WispMCP.WispServer` serves stdio MCP (`wisp mcp`) through `CompatibilityTransport`, which
normalises messages the SDK cannot decode although the protocol allows them (see `docs/mcp.md`). It advertises `respond`, the condensing tools (`triage`,
`summarise_diff`, `draft_change`, `scan_secrets`, `redact`, `condense_log`, `json_shape`, `dependency_audit`, `flaky_tests`, `hot_paths`), and `close_thread` from `ToolCatalog`, whose JSON Schemas and descriptions are the contract other harnesses see; wisp's own tools
are reachable only through `respond`, and are described to clients by the `wisp://tools` resources,
generated from `ToolRegistry.descriptions` (schema from each tool's `GenerationSchema`, limits and example
prompt from the tool's own `WispTool` conformance, so a changed default shows up in the catalogue).
The request types decode and validate arguments as pure, testable values; see
[ADR 0006](decisions/0006-mcp-server-over-stdio.md).

`respond` runs on a conversation thread. `ThreadStore` is an actor keeping threads by id with LRU eviction;
`ConversationThread` is an actor owning one `Agent`, so calls on a thread serialise while threads run
concurrently. Results carry `structuredContent.thread_id`; see
[ADR 0007](decisions/0007-conversation-threads.md). Each `Conversation` tees its audit log into a
`ReceiptCollector`, a bounded in-memory sink; after a turn the server folds that turn's events into a
`Receipt` for `structuredContent.receipt` ([ADR 0021](decisions/0021-receipts.md)), so the result and
the log never disagree. A call may give a JSON Schema; `OutputSchema` converts the accepted subset to a
`DynamicGenerationSchema`, `Agent.respond(to:schema:)` runs guided generation after checking the model
declares it, and the reply's JSON is parsed into `structuredContent.output`
([ADR 0022](decisions/0022-structured-output.md)). `scan_secrets` and `redact` share `SecretScanner` (the rules), `Redactor` (numbered markers), and
`ModelSweep` (the opt-in model pass over rule-redacted text, keeping only values that occur exactly)
with `wisp scan` and `wisp redact` ([ADR 0031](decisions/0031-secret-scanning-and-redaction.md)).
`condense_log` (`LogDigest`, `CrashReport`) and `json_shape` (`JSONShape`) are deterministic: templates
and ranking for logs, a parsed `.ips` for crashes, a merged outline for JSON
([ADR 0032](decisions/0032-log-and-json-condensers.md)). `dependency_audit` (`DependencyAudit`),
`flaky_tests` (`FlakyTests`), and `hot_paths` (`HotPaths`) are deterministic too, and `Triage` runs
`KnownFailures` on each chunk before the model, which sees only what those patterns do not explain
([ADR 0039](decisions/0039-exact-condensers.md)). The server's `condense` helper gives every condensing
tool its conversation, runner, gate, and capture.
`ModelRouting` chooses a model by input size from `Measurements.embedded` and the config's ladder, before
anything runs; `ChangeDraft.route` applies it, honouring an explicit model and passing over a rung that
cannot open ([ADR 0037](decisions/0037-routing-by-input-size.md)).
`draft_change` and `wisp draft` are `ChangeDraft`: a `DiffSummary` report, then one schema-shaped turn,
with the subject and body shape applied in code ([ADR 0035](decisions/0035-change-drafts.md)).
A session's model classifier is wrapped as `CachingRiskClassifier(TimedRiskClassifier(…))`: verdicts are
kept per command line and directory, and only real classifications are timed for `/stats`
([approval.md](approval.md)).
`CustomTool` turns a `tools.custom` definition from the config into a tool whose `GenerationSchema` is
built at run time and whose calls run the substituted line through the registry's `CommandRunner`, gate
included; `ToolRegistry` appends them after the built-ins and drops `tools.disabled`
([ADR 0036](decisions/0036-custom-tools.md)).
`system_info` (`SystemInfo`, `ProcessTable`) answers questions about the Mac from fixed read-only probes
through the conversation's runner without the gate, and from `libproc` for processes, since Seatbelt
will not run the setuid `ps` ([ADR 0034](decisions/0034-system-info.md)).
`wisp watch` is `Watcher` in `WispCore/Session`: a loop over an `AsyncStream` of triggers (start,
FSEvents changes from `FileWatcher`, an interval) whose running, triaging, notifying, and reporting are
injected, so it is tested without time or the file system; its command is cleared once through
`CommandRunner.authorize`, which returns an `Authorized` line that reruns without the gate but with the
policy, sandbox, and audit ([ADR 0033](decisions/0033-watch-mode.md)).
`triage` and `summarise_diff` were the first condensing tools; `DiffSummary` chunks a diff at file
boundaries and joins the model's summaries and flags onto the file list the diff itself gives. `triage` was the first: `Triage`
in `WispCore/Condense` captures a command's output through `CommandRunner` (same policy, gate,
sandbox, audit) or reads a file after the gate clears it, chunks it, judges each chunk through a
schema-shaped turn on a conversation of its own, and merges the findings
([ADR 0023](decisions/0023-condensing-tools.md)).

```
MCP client ──stdio──▶ WispServer ──respond(thread_id)──▶ ThreadStore ──▶ ConversationThread ──▶ Agent ──▶ session ──▶ tools
                                   ──close_thread──▶ ThreadStore
```

### CLI

`wisp` mirrors `fm respond` where semantics match: positional prompt or stdin, `--instructions`,
`--[no-]stream`, repeatable `--tool`. `wisp chat` is a line-oriented REPL with slash commands parsed by
`ChatInput` (`/help`, `/tools`, `/tokens`, `/models`, `/model`, `/stats`, `/history`, `/save`, `/new`,
`/quit`), `--resume <name>`, and `--save <name>`.
`wisp tools` lists the registry. `wisp mcp` serves MCP on stdio. Instructions default to `config.json`.
Exit codes follow swift-argument-parser conventions (64 for usage errors). The chat loop itself is
`ChatLoop` in `WispCore`, with its input and output injected, so the executable only wires the
terminal to it and `ChatLoopTests` runs the whole loop over a scripted model. Chat shows tool activity
live through `ChatEvents.Tap`, an `AuditSink` the conversation is opened with (`Session.openAgent(observer:)`
tees it beside the log and the receipt collector), so the lines the user sees are rendered from the
audited events; `ChatStatus` draws the status line above each prompt; `Style` applies colour only on a
terminal. `TextTable` pads chat output such as `/models` and `/stats` into columns, because tabs drift
in a terminal and in the TUI. `/stats` reads `CallStats`, a fixed-size ring (`Mutex`, 256 calls) that
`Session.begin` creates and every `Conversation` hands to its `Agent`, which records each turn's time,
outcome, and reported prompt tokens; the classifier is wrapped in `TimedRiskClassifier` unless it is the
rules alone, and a classifier's fallback verdict carries `RiskAssessment.failureKey` so it counts as a
failure. `ChatLoop.history` keeps the latest 100 typed lines for `/history`; `wisp-tui` keeps its own
list for Up and Down. `wisp chat --json` is the same loop with its IO mapped onto a JSON Lines protocol
(`ChatProtocol`, `LineRouter`, `JSONApprover`), so a front end in another process, `tools/wisp-tui`,
can own the screen while the session stays here.

## Error handling

Errors are typed enums named `Failure`, one per subsystem, conforming to `Error`, `CustomStringConvertible`,
and `Equatable`, and they keep the underlying cause typed where a caller could act on it
(`Session.Failure.malformedConfig` carries a `ConfigProblem`). Library code never prints or calls
`fatalError`; the CLI is the only place that renders errors to stderr, and `Wisp.usage` is the one
place a bad-input failure from the core becomes a usage error (exit 64). Entry points are the closed
`EntryPoint` enum, so the values `session.start` and the approval store record cannot drift from the docs.

## Concurrency

Swift 6 strict concurrency is enabled. `LanguageModelSession` is not `Sendable`, so `Agent` is a plain
`final class` used from one task at a time, and its async methods are `nonisolated(nonsending)` so they run
in the caller's isolation. That is what lets `ConversationThread` (an actor) own an `Agent`. Do not move
session work into detached tasks.

Actor or `Mutex` is chosen by one rule. A type is an actor when its operations suspend (awaiting a human,
the model, or another actor) or when a change is a multi-step sequence that must not interleave, such as
the approval store's load-mutate-save: `ApprovalGate`, `ApprovalStore`, `ThreadStore`,
`ConversationThread`. A type is a `final class` holding a `Mutex` when every operation is a short
synchronous critical section that callers must not have to `await`: `SessionApprovals`, `TurnClock`,
`AuditLog`, the sinks, `OutputBuffer`, `ClientCapabilityFlags`.

## Visibility

`WispCore` is an implementation library for the two executables, not a published API. A declaration is
`public` when `WispMCP` or `wisp` calls it, or when it is an extension point a new component conforms
to (`WispTool`, `Approver`, `RiskClassifier`, `AuditSink`) or a type such a public signature exposes.
Everything else is internal; tests reach it through `@testable import`.

## Extension points

- New in-process tool: add a file under `Tools/`, append to `ToolRegistry.all`, add a test for its pure helper.
- New Rust tool binary: `cargo new --bin` under `tools/`, list it in the workspace, then either let the model
  reach it through `run_command` or give it a dedicated Swift `Tool` whose description tells the model when to
  use it.
- New MCP tool: add a `Tool` to `ToolCatalog`, a request type, and a case in `WispServer.call`.
- Thread persistence or context management: extend `ConversationThread`; record the choice in an ADR.
- Session persistence (transcript save/resume, as `fm` does with `~/.fm/sessions/`) would live in `Agent`.
- Structured output (`fm respond --schema`) would be a `respond(to:generating:)` overload on `Agent`.
