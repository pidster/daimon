# wisp

**wisp** is a small, on-device AI agent for the Mac. It runs Apple's built-in Foundation Model, the same
one behind Apple Intelligence and the `fm` command, and gives it tools: it can run shell commands, read
and edit files, tell the time, look at its own state, and send you a macOS notification, and it can be
extended with more. With the default model nothing leaves your
machine; Apple's Private Cloud Compute model is available as an explicit opt-in, and any model served by a
local Ollama can be chosen with `--model ollama:<name>`. Commands the model runs
may use the network unless you turn that off.

It has two faces:

- **A command-line tool.** Ask it a question, have it run your tests and explain a failure, or chat with it.
  On a terminal the chat runs in `wisp-tui`: the conversation scrolls in your terminal's own history
  above a pinned input and status line.
- **An MCP server.** Other agent harnesses such as Claude Code or Codex can hand it self-contained work to do
  locally: run a build, summarise a file, classify some text.

It is deliberately a *microharness*: the smallest correct agent loop, not a framework. What makes it worth
using is the care around that loop. Every command the model wants to run passes a deny list, runs inside a
sandbox that confines what it can write, is classified for risk, and needs your approval when it matters.
Everything that happens is written to an audit log you can read back, and anything it remembers can be
listed and revoked. [trust.md](docs/trust.md) states exactly what it can and cannot do to your Mac.

Apple's Private Cloud Compute model is not available from this build: it needs an entitlement Apple
grants only to signed App Store apps ([backends.md](docs/backends.md), "Private Cloud Compute").

## Quick start

Requirements: an Apple silicon Mac on macOS 27 or later with Apple Intelligence enabled, and Homebrew.

```bash
brew install pidster/tap/wisp
wisp doctor                     # checks the model, sandbox, config, and home directory
wisp "What is the date in Tokyo?"
wisp chat                       # interactive; /help for commands, /models and /model to switch models
wisp --yes "Run the tests in $PWD and tell me if they pass"   # non-interactive: approve risky commands
wisp logs --last 20             # what just happened, from the audit log
wisp approvals                  # what it has been told to remember; revoke or clear here
make test; wisp notify "Tests finished" --sound   # a macOS notification, from you or from the model
wisp watch 'swift test 2>&1'    # rerun on every save; a notification when it starts or stops failing
git diff --cached | wisp scan   # credentials in a commit, before it is made
```

Running tests is a "moderate" action, so `chat` asks you before doing it; plain `wisp "…"` cannot ask
and refuses unless you pass `--yes`. State lives in `~/.wisp`: an optional `config.json`, saved chat
transcripts, remembered approvals, and the audit log. Upgrade with `brew upgrade wisp`, remove with
`brew uninstall wisp` and `rm -rf ~/.wisp`.

To let another harness use it, register it as an MCP server. For Claude Code, in `.mcp.json`:

```json
{
    "mcpServers": {
        "wisp": {
            "command": "/opt/homebrew/bin/wisp",
            "args": ["mcp"]
        }
    }
}
```

It exposes `respond` (run a task on the on-device model, with wisp's tools; pass back the returned
`thread_id` to continue a conversation), `triage` (run or read build and test output and get back only
the failures), `summarise_diff` (a diff as per-file lines and review flags), `scan_secrets` (credentials
and personal data found, masked), `redact` (text with them replaced), `condense_log` (a log as its distinct messages, or a crash report as
what explains it), `json_shape` (a JSON file's structure without its data), and `close_thread`. The raw output
behind the condensing tools never leaves the Mac. wisp's own tools are used by the
model, not called directly.

## Documentation

Everything is under [docs/](docs/README.md). Start with the one that matches your question.

| If you want to… | Read |
| --- | --- |
| Understand what wisp is for and what is out of scope | [objective.md](docs/objective.md) |
| Use the command line: subcommands, flags, `config.json`, exit codes | [wisp.md](docs/wisp.md) |
| See what the model can do and the limits on each tool | [tools/](docs/tools/README.md) |
| Know how well each delegated task works, as measured | [measurements.md](docs/measurements.md) |
| Choose a model or a local backend | [backends.md](docs/backends.md) |
| Connect it to another harness over MCP | [mcp.md](docs/mcp.md) |
| Know what it can do to your Mac, what it remembers, and how to undo | [trust.md](docs/trust.md) |
| Know how commands are confined and when you are asked | [tools/run_command.md](docs/tools/run_command.md), [approval.md](docs/approval.md) |
| Read or query the audit log, or debug wisp itself | [logging.md](docs/logging.md) |
| Understand how the code is put together | [design.md](docs/design.md) |
| Know why a decision was made | [decisions/](docs/decisions/) (one record per decision) |
| Work on the code to the project's standard | [engineering.md](docs/engineering.md) |
| Cut a release | [release.md](docs/release.md) |

Two background pages record what we learned about the platform: [context-management.md](docs/context-management.md)
on living inside a 4k-token window, and [policy-and-sandboxing.md](docs/policy-and-sandboxing.md) on what
macOS and the framework offer for confinement.

## Setup for developers

You need macOS 27 and Xcode 27 (the Command Line Tools alone lack the `@Generable` macro plugin), and
Rust 1.98 or later for the terminal front end in `tools/`.

```bash
git clone git@github.com:pidster/wisp.git
cd wisp
scripts/check install-hooks       # once: enables the pre-commit gate
cd harness
swift build
.build/debug/wisp tools
.build/debug/wisp "What is the date in Tokyo?"
cd ../tools
cargo build                       # wisp-tui, the terminal front end
WISP_BIN=../harness/.build/debug/wisp target/debug/wisp-tui
```

The repository is laid out as:

| Path | What it is |
| --- | --- |
| `harness/` | The Swift package: the `wisp` binary, `WispCore`, `WispMCP`, and the model backends |
| `tools/` | The Cargo workspace: `wisp-tui`, the terminal front end over `wisp chat --json` |
| `docs/` | Documentation and decision records |
| `scripts/check` | The quality gate: lint, warnings-as-errors build, tests, hygiene, coverage, model eval |

How we work, in short:

- `scripts/check` is the whole gate and the pre-commit hook runs it. Lint is strict, warnings are errors,
  Swift 6 strict concurrency stays on, and no escape hatches.
- Tests never need the model. The model is exercised by running the binary, and by `scripts/check eval`
  for the classifier and every delegated task ([measurements.md](docs/measurements.md)).
- A change is done when it is tested, documented in code, and documented in `docs/`, in the same commit.
  Non-obvious or hard-to-reverse choices get a decision record.
- Dogfooding: `.mcp.json` registers this repository's own release build (`swift build -c release`) as an
  MCP server, so Claude Code sessions here can use it.

See [engineering.md](docs/engineering.md) for the full standard and [AGENTS.md](AGENTS.md) for the
orientation given to AI agents working in this repository.
