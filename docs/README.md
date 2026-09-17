# daimon documentation

| Document | Purpose |
| --- | --- |
| [objective.md](objective.md) | What daimon is for and what "done" looks like |
| [daimon.md](daimon.md) | Command reference: subcommands, flags, `~/.daimon`, `config.json`, exit codes |
| [tools/](tools/README.md) | One page per model-facing tool: contract, result format, limits |
| [mcp.md](mcp.md) | daimon as an MCP server: client setup, tools, errors |
| [design.md](design.md) | Architecture: components, data flow, extension points |
| [fm-cli.md](fm-cli.md) | What the Apple `fm` command family does and does not offer, as observed |
| [approval.md](approval.md) | Risk classification (rules + on-device model), approval per entry point, eval results |
| [logging.md](logging.md) | The audit log (format, kinds, `daimon logs`) and diagnostics (`DAIMON_LOG`, unified logging) |
| [context-management.md](context-management.md) | The small context window: framework APIs, what daimon does, design rules |
| [policy-and-sandboxing.md](policy-and-sandboxing.md) | Investigation of tool policy and sandboxing options (decision pending) |
| [release.md](release.md) | How a release is cut: tag, tarball, GitHub release, Homebrew tap formula |
| [engineering.md](engineering.md) | Standards, tooling, the pre-commit gate, and CI |
| [decisions/](decisions/) | Architecture Decision Records, one per significant decision |

Conventions: documentation is updated in the same change as the code it describes (see the definition of done
in [engineering.md](engineering.md)). Documents describe the current state and are edited in place. Decisions are append-only; a
superseded ADR keeps its file and gets a `Superseded by` line. Add an ADR whenever a choice would be
non-obvious to a newcomer or expensive to reverse.
