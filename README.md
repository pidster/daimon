# daimon

**daimon** is a small, on-device AI agent for the Mac. It runs Apple's built-in Foundation Model, the same
one behind Apple Intelligence and the `fm` command, and gives it tools: it can run shell commands, read
files, and tell the time, and it can be extended with more. Nothing leaves your machine.

It has two faces:

- **A command-line tool.** Ask it a question, have it run your tests and explain a failure, or chat with it.
- **An MCP server.** Other agent harnesses such as Claude Code or Codex can hand it self-contained work to do
  locally: run a build, summarise a file, classify some text.

It is deliberately a *microharness*: the smallest correct agent loop, not a framework. What makes it worth
using is the care around that loop. Every command the model wants to run passes a policy, runs inside a
kernel-enforced sandbox, is classified for risk, and needs your approval when it matters. Everything that
happens is written to an audit log you can read back.

## Quick start

> The install package is in progress. Until it ships, follow [Setup for developers](#setup-for-developers)
> to build from source; the commands below are the same once `daimon` is on your `PATH`.

Requirements: macOS 27 or later with Apple Intelligence enabled (`fm available` should say the system model
is available).

```bash
daimon "What is the date in Tokyo?"
daimon "Run the tests in $PWD and tell me if they pass"
daimon chat --save today          # interactive; type /help for commands
daimon logs --last 20             # what just happened, from the audit log
```

The first time the model wants to run something risky, `chat` asks you; plain `daimon` refuses unless you
pass `--yes`. State lives in `~/.daimon`: an optional `config.json`, saved chat transcripts, and the audit
log.

To let another harness use it, register it as an MCP server. For Claude Code, in `.mcp.json`:

```json
{
    "mcpServers": {
        "daimon": {
            "command": "/path/to/daimon",
            "args": ["mcp"]
        }
    }
}
```

It exposes `respond` (run a task on the on-device model, with daimon's tools; pass back the returned
`thread_id` to continue a conversation), `run_command`, and `close_thread`.

## Documentation

Everything is under [docs/](docs/README.md). Start with the one that matches your question.

| If you want to… | Read |
| --- | --- |
| Understand what daimon is for and what is out of scope | [objective.md](docs/objective.md) |
| Use the command line: subcommands, flags, `config.json`, exit codes | [daimon.md](docs/daimon.md) |
| See what the model can do and the limits on each tool | [tools/](docs/tools/README.md) |
| Connect it to another harness over MCP | [mcp.md](docs/mcp.md) |
| Know how commands are confined and when you are asked | [tools/run_command.md](docs/tools/run_command.md), [approval.md](docs/approval.md) |
| Read or query the audit log, or debug daimon itself | [logging.md](docs/logging.md) |
| Understand how the code is put together | [design.md](docs/design.md) |
| Know why a decision was made | [decisions/](docs/decisions/) (one record per decision) |
| Work on the code to the project's standard | [engineering.md](docs/engineering.md) |

Two background pages record what we learned about the platform: [context-management.md](docs/context-management.md)
on living inside a 4k-token window, and [policy-and-sandboxing.md](docs/policy-and-sandboxing.md) on what
macOS and the framework offer for confinement.

## Setup for developers

You need macOS 27 and Xcode 27 (the Command Line Tools alone lack the `@Generable` macro plugin). Rust is
optional until the first tool crate lands.

```bash
git clone git@github.com:pidster/daimon.git
cd daimon
scripts/check install-hooks       # once: enables the pre-commit gate
cd harness
swift build
.build/debug/daimon tools
.build/debug/daimon "What is the date in Tokyo?"
```

The repository is laid out as:

| Path | What it is |
| --- | --- |
| `harness/` | The Swift package: the `daimon` binary and the `DaimonCore` and `DaimonMCP` libraries |
| `tools/` | A Cargo workspace reserved for Rust tool binaries |
| `docs/` | Documentation and decision records |
| `scripts/check` | The quality gate: lint, warnings-as-errors build, tests, hygiene, coverage, model eval |

How we work, in short:

- `scripts/check` is the whole gate and the pre-commit hook runs it. Lint is strict, warnings are errors,
  Swift 6 strict concurrency stays on, and no escape hatches.
- Tests never need the model. The model is exercised by running the binary, and by `scripts/check eval`
  for the risk classifier.
- A change is done when it is tested, documented in code, and documented in `docs/`, in the same commit.
  Non-obvious or hard-to-reverse choices get a decision record.
- Dogfooding: `.mcp.json` registers this repository's own release build (`swift build -c release`) as an
  MCP server, so Claude Code sessions here can use it.

See [engineering.md](docs/engineering.md) for the full standard and [CLAUDE.md](CLAUDE.md) for the
orientation given to AI agents working in this repository.
