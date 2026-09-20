# daimon documentation

| Document | Purpose |
| --- | --- |
| [trust.md](trust.md) | What daimon can do to your Mac, what leaves it, what it remembers, how to see and undo |
| [objective.md](objective.md) | What daimon is for and what "done" looks like |
| [daimon.md](daimon.md) | Command reference: subcommands, flags, `~/.daimon`, `config.json`, exit codes |
| [tools/](tools/README.md) | One page per model-facing tool: contract, result format, limits |
| [mcp.md](mcp.md) | daimon as an MCP server: client setup, `respond`, `triage`, structured output, receipts, errors |
| [design.md](design.md) | Architecture: components, data flow, extension points |
| [fm-cli.md](fm-cli.md) | What the Apple `fm` command family does and does not offer, as observed |
| [approval.md](approval.md) | Risk classification (rules + on-device model), approval scopes and persistence, eval results |
| [logging.md](logging.md) | The audit log (format, kinds, `daimon logs`) and diagnostics (`DAIMON_LOG`, unified logging) |
| [context-management.md](context-management.md) | The small context window: framework APIs, what daimon does, design rules |
| [policy-and-sandboxing.md](policy-and-sandboxing.md) | Survey of tool policy and sandboxing options and which layers are implemented |
| [decisions/0013-model-selection.md](decisions/0013-model-selection.md) | Which model a session runs on (`system` or `private-cloud`), and why the default stays on device |
| [decisions/0025-context-estimation.md](decisions/0025-context-estimation.md) | The agent condenses ahead of a known window from the usage the runtime reports, because local runtimes truncate silently |
| [decisions/0024-edit-file.md](decisions/0024-edit-file.md) | `edit_file` writes inside the sandbox's writable set, needs approval like a command, and replaces only an exact single match |
| [decisions/0023-condensing-tools.md](decisions/0023-condensing-tools.md) | Purpose-built MCP tools condense local content on device; `triage` runs or reads build output and returns only the failures, amending ADR 0006 |
| [decisions/0022-structured-output.md](decisions/0022-structured-output.md) | A caller's JSON Schema shapes the reply through guided generation, in an accepted subset, refused when the model does not declare it |
| [decisions/0021-receipts.md](decisions/0021-receipts.md) | `respond` returns a receipt of the turn, derived from the audit events rather than collected separately |
| [decisions/0020-coreml-risk-classifier.md](decisions/0020-coreml-risk-classifier.md) | A Core ML text classifier can judge commands behind a versioned contract, beside the rules, never lowering a level |
| [decisions/0019-model-backends.md](decisions/0019-model-backends.md) | Model backends are a registry keyed by scheme; capabilities are declared by the framework, the runtime, or config, and checked before a session opens |
| [decisions/0018-introspection.md](decisions/0018-introspection.md) | daimon's own config, status, approvals, and audit are readable, read-only, through the model's `inspect` tool, MCP resources, and the CLI |
| [decisions/0017-three-layer-instructions.md](decisions/0017-three-layer-instructions.md) | daimon's system prompt (a resource file), the operator's extension, and the caller's instructions, rendered in order |
| [decisions/0016-local-runtimes-through-an-executor.md](decisions/0016-local-runtimes-through-an-executor.md) | Locally installed models plug in through a daimon-supplied executor; what the spike measured; `ollama:<name>` built |
| [release.md](release.md) | How a release is cut: tag, tarball, GitHub release, Homebrew tap formula |
| [backlog.md](backlog.md) | Agreed work not yet started: more condensing tools, a task catalogue, sampling, deferred backends |
| [engineering.md](engineering.md) | Standards, tooling, the pre-commit gate, and CI |
| [backends.md](backends.md) | Model backends: Apple's, Ollama, Core AI, MLX; asset preparation, naming, declared capabilities, errors |
| [decisions/](decisions/) | Architecture Decision Records, one per significant decision |
| [proposals/2026-09-20-escalations.md](proposals/2026-09-20-escalations.md) | For review: two escalation verbs (approval, inquiry) and a choice of channels, including a non-blocking hand-off to the calling agent |
| [reviews/](reviews/) | Dated code and documentation reviews with their todo lists and status |

Conventions: documentation is updated in the same change as the code it describes (see the definition of done
in [engineering.md](engineering.md)). Documents describe the current state and are edited in place. Decisions are append-only; a
superseded ADR keeps its file and gets a `Superseded by` line. Add an ADR whenever a choice would be
non-obvious to a newcomer or expensive to reverse.
