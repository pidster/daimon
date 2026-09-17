# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What daimon is

An on-device, tool-using AI microharness for macOS, written in Swift on Apple's Foundation Models framework
(the model behind Apple Intelligence and the `fm` CLI). One binary, `daimon`, with two faces: a CLI
(`respond`, `chat`, `tools`, `logs`) and an MCP server over stdio (`mcp`) that other harnesses delegate
local work to. Every command the model runs passes a policy, a Seatbelt sandbox, a risk classifier, and,
when risky, human approval; everything is written to a verbatim audit log.

`docs/README.md` is the map. Read the page for the area you are touching before changing it; the decision
records under `docs/decisions/` explain why things are the way they are, and you must not reverse one
without a new ADR.

## Layout

| Path | Contents |
| --- | --- |
| `harness/` | Swift package. Targets: `DaimonCore` (all logic), `DaimonMCP` (MCP server), `daimon` (CLI, argument parsing only), tests. |
| `tools/` | Cargo workspace reserved for Rust tool binaries. Empty; checks activate with the first crate. |
| `docs/` | Documentation and ADRs. Part of every change (see Definition of done). |
| `scripts/check` | The quality gate and the pre-commit hook's body. |

## Commands

Swift commands run inside `harness/`; the gate runs from anywhere.

```
scripts/check install-hooks        # once per clone
scripts/check                      # hygiene + strict lint + warnings-as-errors build + tests (the gate)
scripts/check format               # swift-format and rustfmt auto-fix
scripts/check coverage             # per-file line coverage (not in the gate)
scripts/check eval                 # on-device model classifier evaluation; slow; not in the gate

cd harness && swift build                                        # -> .build/debug/daimon
cd harness && swift test --filter CommandRunnerTests             # one suite; append /testName for one test
cd harness && swift build -c release                             # -> .build/release/daimon (what .mcp.json runs)
```

Smoke-testing against the live model (never in unit tests):

```
export DAIMON_HOME=/tmp/daimon-scratch     # keep smoke state out of the real ~/.daimon
harness/.build/debug/daimon tools
harness/.build/debug/daimon --yes "Use run_command to run: uname -m"
harness/.build/debug/daimon chat            # /help, /tokens, /save, /new, /quit; answers y/n/a to approvals
harness/.build/debug/daimon logs --last 20  # audit summaries; --json for raw events
DAIMON_LOG=debug harness/.build/debug/daimon "…"   # mirror diagnostics to stderr
```

To drive `daimon mcp` by hand, pipe JSON-RPC lines and keep stdin open (`; sleep 5` in the producing
subshell); the server exits on EOF. `docs/mcp.md` has a ready-made example.

## Architecture in one paragraph

`Agent` wraps one `LanguageModelSession`; the framework runs the tool loop. `ToolRegistry` is the single
list of tools the model sees (`current_date`, `run_command`, `read_file`), each wrapped by `AuditedTool`.
`CommandRunner` checks `CommandPolicy` (deny/allow regexes), consults `ApprovalGate` (rules plus on-device
model classifier, ask at `moderate` and above through an `Approver` per entry point), then runs `/bin/sh -c`
under `sandbox-exec` with a generated profile, bounded output and a timeout. `FileReader` pages files.
`Home`, `Config`, and `TranscriptStore` are `~/.daimon`. `AuditLog` writes JSON Lines; `Diagnostics` wraps
unified logging. `ContextPolicy` recovers from context overflow by dropping old turns. `DaimonMCP` exposes
`respond` (per-`thread_id` conversations held by `ThreadStore`/`ConversationThread` actors), `run_command`,
and `close_thread`. Details: `docs/design.md`.

## Rules

- **Definition of done.** A change is done when it is tested (without the model), documented in code, and
  documented under `docs/` in the same commit: tool page, `daimon.md`, `mcp.md`, `logging.md`, `design.md`,
  or an ADR as appropriate. If no doc needs changing, say so in the commit message. The hook reminds you.
- **Gate.** `scripts/check` must pass before every commit; the hook runs it. Strict lint (every public
  declaration documented, no force unwrap or try), warnings as errors, Swift 6 strict concurrency. Fix
  concurrency diagnostics by restructuring: no `@unchecked Sendable`, no `nonisolated(unsafe)`. `Agent`'s
  async methods are `nonisolated(nonsending)` so actors can own one; keep new async APIs consistent.
- **Tests never need the model.** Keep logic in pure functions and test those; `ModelEvalTests` is the one
  model-dependent suite and runs only via `scripts/check eval`. Tests drive the real sandbox, so they write
  only under the working directory and temp.
- **Errors are typed** enums with `CustomStringConvertible`; no `fatalError` or `print` in library code.
  Tool failures the model should react to are returned as text, not thrown.
- **Bound every tool result** (4 KiB or paged); the model's window is about 4k tokens. Keep tool
  descriptions short. See `docs/context-management.md`.
- **Audit new behaviour.** New event kinds go in `AuditEvent.Kind` and `docs/logging.md`.
- **Commits** are small and single-purpose; subject says what, body says why. Do not pass an explicit
  `user.email` to git; the configured noreply identity is required for pushes.
- **CI is disabled** until a macOS 27 runner exists; the hook is the only automated gate.

## Gotchas

- Needs macOS 27 and Xcode 27 as the active developer directory; the Command Line Tools lack the
  `@Generable` macro plugin. `PackageDescription` has no `.v27`, so the platform is `.macOS("27.0")`.
- Sandboxes do not nest: inside daimon's sandbox, SwiftPM needs `swift build --disable-sandbox`.
- Seatbelt matches real paths; profile paths go through `realpath` (`/tmp` and `/var` are symlinks).
- The `@Generable` macro rejects extra protocol conformances on the same declaration; add them in an
  extension (see `RiskLevel`).
- swift-format reflows code; when patching by string replacement, re-read the file after formatting.

## MCP servers (`.mcp.json`)

- `daimon`: this repository's own release build, for dogfooding. Build it first (`swift build -c release`),
  then `/mcp` to connect. Use `respond` to delegate small, self-contained tasks to the on-device model
  (pass back `thread_id` to continue), `run_command` to run something locally, `close_thread` when done.
  Risky commands need approval through elicitation; if this client lacks it they are refused, and the
  alternatives are running the command here or starting the server with `--yes`.
- `codex`: `codex mcp-server`, the OpenAI Codex CLI; needs `codex` on `PATH`.
