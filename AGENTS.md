# AGENTS.md

Instructions for any coding agent working in this repository: Claude Code, Codex, or another harness.
Everything here applies to all of them. Anything that only applies to one harness is in the last section,
under that harness's name, or in that harness's own file (`CLAUDE.md` for Claude Code, which imports this
one). If you are a different harness, read this file in full and take only your own subsection.

## What daimon is

An on-device, tool-using AI microharness for macOS, written in Swift on Apple's Foundation Models framework
(the model behind Apple Intelligence and the `fm` CLI). One binary, `daimon`, with two faces: a CLI
(`respond`, `chat`, `tools`, `models`, `logs`, `doctor`, `approvals`) and an MCP server over stdio (`mcp`) that other
harnesses delegate local work to. Every command the model runs passes a policy, a Seatbelt sandbox, a risk classifier, and,
when risky, human approval; everything is written to a verbatim audit log.

`docs/README.md` is the map. Read the page for the area you are touching before changing it; the decision
records under `docs/decisions/` explain why things are the way they are, and you must not reverse one
without a new ADR. Language- and area-specific rules live in `.claude/rules/` (`swift.md`, `rust.md`,
`docs.md`, `shell.md`); each file's header lists the paths it applies to. Claude Code loads them by path
automatically; every other agent reads the matching file before touching those paths. This file holds
only what applies everywhere and to every agent.

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
`private-cloud`, or `ollama:<name>` through daimon's own executor, ADR 0016; adapters are obsoleted on macOS 27, ADR 0013); the framework runs the tool loop. `ToolRegistry` is the single
list of tools the model sees (`current_date`, `run_command`, `read_file`), each wrapped by `AuditedTool`.
`CommandRunner` checks `CommandPolicy` (deny/allow regexes), consults `ApprovalGate` (rules plus on-device
model classifier, ask at `moderate` and above through an `Approver` per entry point), then runs `/bin/sh -c`
under `sandbox-exec` with a generated profile, bounded output and a timeout. `FileReader` pages files.
`Home`, `Config`, and `TranscriptStore` are `~/.daimon`. `Prompting` layers daimon's own system prompt (the
file `harness/Sources/DaimonCore/Resources/system-prompt.md`, embedded at build time by the
`EmbedSystemPrompt` plugin), the operator's `systemPromptExtension`, and the caller's instructions (ADR 0017). `AuditLog` writes JSON Lines; `Diagnostics` wraps
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
  A user-visible change also gets a line under `## Unreleased` in `CHANGELOG.md`; the release script
  publishes that section as the release notes and refuses to release without one.
- **Gate.** `scripts/check` must pass before every commit; the hook runs it. Strict lint, warnings as
  errors, strict concurrency, no escape hatches. Language rules are in `.claude/rules/`.
- **Tests never need the model.** `ModelEvalTests` is the one model-dependent suite and runs only via
  `scripts/check eval`; `OllamaLiveTests` runs only under `DAIMON_OLLAMA_TESTS=1`. To drive the agent,
  the tool loop, or the MCP server end to end without a model, use `ScriptedModel` from
  `Tests/DaimonTestSupport` (ADR 0016); `DaimonServerWireTests` shows the pattern over a real client.
- **Bound every tool result** (4 KiB or paged); the model's window is about 4k tokens. Keep tool
  descriptions short. See `docs/context-management.md`.
- **Audit new behaviour.** New event kinds go in `AuditEvent.Kind` and `docs/logging.md`.
- **Commits** are small and single-purpose; subject says what, body says why. Do not pass an explicit
  `user.email` to git; the configured noreply identity is required for pushes.
- **Releases** run the full test suite and `scripts/check coverage-gate` in preflight. Line coverage
  must not fall below `harness/coverage-baseline`; after adding tests, record the new figure with
  `scripts/check coverage-baseline` and commit it (`docs/release.md`).
- **CI is disabled** until a macOS 27 runner exists; the hook is the only automated gate.

## Gotchas that cross languages

- Seatbelt refuses a nested profile that differs from the outer one. Inside daimon's sandbox, SwiftPM
  needs `swift build --disable-sandbox` (Cargo is unaffected); daimon inside a sandbox detects the refusal
  and runs commands under the outer sandbox instead (`docs/tools/run_command.md`).
- Seatbelt matches real paths; profile paths go through `realpath` (`/tmp` and `/var` are symlinks).
- Stdout is the MCP protocol channel while `daimon mcp` runs; diagnostics go to stderr or unified logging.

## Working through daimon's MCP server

**Run every git command through daimon's `respond` tool**, never through your own shell: status, log,
diff, add, commit, push. There is no direct `run_command` MCP tool by decision; the model behind
`respond` runs the command with its own `run_command` tool, so each one is classified, sandboxed,
approved, and audited as a turn. The tool is named by your harness's convention for the `daimon` server
(Claude Code: `mcp__daimon__respond`; Codex: the `respond` tool of the `daimon` server).

Open one thread for git and reuse it. When the thread starts, pass all four of these; they are refused on
an existing thread:

- `thread_id`: `git` (or `git2`, `git3` if the thread was closed).
- `tools`: `["run_command"]`, so the model has nothing else to reach for.
- `model`: `ollama:qwen3-coder`, the local Ollama model. It follows a fixed instruction reliably and its
  context window is far larger than the on-device model's, so a thread survives many commits with hook
  output. If Ollama is not running the thread fails to start with a clear error; then use the default
  `system` model and keep prompts short.
- `instructions` (the conversation layer; daimon's own system prompt and the config extension stay
  underneath it):

  ```
  You run git commands for a coding assistant. Run exactly the command line given between backticks,
  once, in the working directory given, with the run_command tool. Do not modify the command, add flags,
  or run anything else. Reply with the exit status and the output verbatim, and nothing else.
  ```

Prompt shape for each turn, with the command between backticks so a trailing period is never taken as
part of it:

```
Use run_command with working directory <repo> to run exactly the command line between the backticks:
`<command>`
Report the exit status and output verbatim, nothing else.
```

Put commit messages in a file and commit with `git commit -q -F <path> 2>&1 | tail -1` so the hook's
test output does not fill the reply; push with `git push origin main 2>&1 | tail -1`. Expect an approval
dialog for commands that change repository state; choose "This session" for repeated shapes. The
pre-commit hook then runs inside daimon's sandbox, which `scripts/check` detects. If daimon is not
connected, say so and ask the user to reconnect it rather than falling back to your own shell.

The `daimon` server is this repository's own release build, for dogfooding, launched through
`scripts/daimon-mcp`. **If the server fails to connect at start-up, the cause is almost always a missing
release build**: tell the user to run `cd harness && swift build -c release` and reconnect, and offer to
run the build yourself. The build is also stale after code changes until it is rerun. Use `respond` to
delegate small, self-contained tasks to the on-device model (pass back `thread_id` to continue) and
`close_thread` when done. Read the `daimon://tools` resource (or run `daimon tools --markdown`) for the
model's tools and the prompt shapes that work; `daimon://config`, `daimon://status`, `daimon://approvals`,
and `daimon://audit/{thread_id}` show its state. Commands the model runs need approval through MCP
elicitation; a client without it gets a refusal.

## Harness-specific notes

Mark anything you add here with the harness it is for. Nothing in this section applies to every agent.

### Claude Code

- Reads `CLAUDE.md`, which imports this file, and loads `.claude/rules/*.md` by path automatically.
- MCP servers come from `.mcp.json`: `daimon` (above) and `codex` (`codex mcp-server`, the OpenAI Codex
  CLI, for delegating to Codex; needs `codex` on `PATH`). Tools are named `mcp__<server>__<tool>`.
- Reconnect a server with `/mcp`. When a daimon approval dialog is stuck, `/mcp reconnect daimon` and
  retry the turn.
- Ask the user a question with `AskUserQuestion`; that is the harness's dialog, not daimon's.

### Codex

- Reads this file directly. There is no automatic path-scoped loading: open `.claude/rules/<lang>.md`
  for the language you are editing before you start.
- Connect daimon as an MCP server in `~/.codex/config.toml` as shown in `docs/mcp.md`; the release build
  must exist (`cd harness && swift build -c release`) or the server exits at start-up with instructions.
- daimon 0.1.5 or later accepts Codex's `initialize` (earlier versions refused its `experimental`
  capability; see `docs/mcp.md`).
