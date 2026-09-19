# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What daimon is

An on-device, tool-using AI microharness for macOS, written in Swift on Apple's Foundation Models framework
(the model behind Apple Intelligence and the `fm` CLI). One binary, `daimon`, with two faces: a CLI
(`respond`, `chat`, `tools`, `logs`, `doctor`, `approvals`) and an MCP server over stdio (`mcp`) that other
harnesses delegate local work to. Every command the model runs passes a policy, a Seatbelt sandbox, a risk classifier, and,
when risky, human approval; everything is written to a verbatim audit log.

`docs/README.md` is the map. Read the page for the area you are touching before changing it; the decision
records under `docs/decisions/` explain why things are the way they are, and you must not reverse one
without a new ADR. Language- and area-specific guidance lives in `.claude/rules/` (Swift, Rust, docs,
shell) and loads when you touch matching files; this file holds only what applies everywhere.

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
scripts/release X.Y.Z --dry-run    # release preflight, build, package; remote steps printed (docs/release.md)

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

`Agent` wraps one `LanguageModelSession` created by a `ResolvedModel` (`ModelSelection`: `system` or
`private-cloud`; adapters are unavailable on macOS; ADR 0013); the framework runs the tool loop. `ToolRegistry` is the single
list of tools the model sees (`current_date`, `run_command`, `read_file`), each wrapped by `AuditedTool`.
`CommandRunner` checks `CommandPolicy` (deny/allow regexes), consults `ApprovalGate` (rules plus on-device
model classifier, ask at `moderate` and above through an `Approver` per entry point), then runs `/bin/sh -c`
under `sandbox-exec` with a generated profile, bounded output and a timeout. `FileReader` pages files.
`Home`, `Config`, and `TranscriptStore` are `~/.daimon`. `AuditLog` writes JSON Lines; `Diagnostics` wraps
unified logging. `ContextPolicy` recovers from context overflow by dropping old turns. `Session.begin` is
the single set-up path for every face; `respond` and `chat` open the session's own `Conversation`, and
`DaimonMCP` opens one per `thread_id` through `Session.conversation` (threads held by
`ThreadStore`/`ConversationThread` actors), so all of them share one config, approval store, and
session-approval set. `DaimonMCP` exposes `respond` and `close_thread`; daimon's own tools are reachable
only through `respond`. Details: `docs/design.md`.

## Rules

- **Definition of done.** A change is done when it is tested (without the model), documented in code, and
  documented under `docs/` in the same commit: tool page, `daimon.md`, `mcp.md`, `logging.md`, `design.md`,
  or an ADR as appropriate. If no doc needs changing, say so in the commit message. The hook reminds you.
- **Gate.** `scripts/check` must pass before every commit; the hook runs it. Strict lint, warnings as
  errors, strict concurrency, no escape hatches. Language rules are in `.claude/rules/`.
- **Tests never need the model.** `ModelEvalTests` is the one model-dependent suite and runs only via
  `scripts/check eval`; `OllamaSpikeTests` runs only under `DAIMON_OLLAMA_TESTS=1`. To exercise the agent
  and tool loop without a model, use a scripted `LanguageModel` (see `ExecutorSpikeTests`, ADR 0016).
- **Bound every tool result** (4 KiB or paged); the model's window is about 4k tokens. Keep tool
  descriptions short. See `docs/context-management.md`.
- **Audit new behaviour.** New event kinds go in `AuditEvent.Kind` and `docs/logging.md`.
- **Commits** are small and single-purpose; subject says what, body says why. Do not pass an explicit
  `user.email` to git; the configured noreply identity is required for pushes.
- **CI is disabled** until a macOS 27 runner exists; the hook is the only automated gate.

## Gotchas that cross languages

- Seatbelt refuses a nested profile that differs from the outer one. Inside daimon's sandbox, SwiftPM
  needs `swift build --disable-sandbox` (Cargo is unaffected); daimon inside a sandbox detects the refusal
  and runs commands under the outer sandbox instead (`docs/tools/run_command.md`).
- Seatbelt matches real paths; profile paths go through `realpath` (`/tmp` and `/var` are symlinks).
- Stdout is the MCP protocol channel while `daimon mcp` runs; diagnostics go to stderr or unified logging.

## MCP servers (`.mcp.json`)

**Run every git command through daimon by prompting `mcp__daimon__respond`**, never through Bash:
status, log, diff, add, commit, push. There is no direct `run_command` MCP tool by decision; the on-device
model runs the command with its own `run_command` tool, so each one is classified, sandboxed, approved,
and audited as a turn. Prompt shape that works: `Use run_command with working directory <repo> to run
exactly: <command> . Report the exit status and output verbatim, nothing else.` Put commit messages in a
file and commit with `git commit -q -F <path>` so the command stays short. Use a `thread_id` such as
`git` and pass `tools: ["run_command"]` so the model has nothing else to reach for. Expect an approval
dialog for commands that change repository state; choose "This session" for repeated shapes.
The pre-commit hook then runs inside daimon's sandbox, which `scripts/check` detects. If daimon is not
connected, say so and ask the user to run `/mcp` rather than falling back to Bash.

- `daimon`: this repository's own release build, for dogfooding, launched through `scripts/daimon-mcp`.
  **If the session starts with the `daimon` server failed to connect, the cause is almost always a missing
  release build.** Do not treat the tools as unavailable: tell the user to run
  `cd harness && swift build -c release` and then restart the harness or run `/mcp`, and offer to run the
  build yourself. The launcher prints the same instructions to stderr. The build is also stale after code
  changes until it is rerun. Use `respond` to delegate small, self-contained tasks to the on-device model
  (pass back `thread_id` to continue) and `close_thread` when done. Read the `daimon://tools` resource
  (or run `daimon tools --markdown`) for the model's tools and the prompt shapes that work. Commands the model runs need approval
  through elicitation; if this client lacks it they are refused.
- `codex`: `codex mcp-server`, the OpenAI Codex CLI; needs `codex` on `PATH`.
