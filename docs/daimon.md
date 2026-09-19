# daimon command reference

`daimon` runs Apple's on-device Foundation Model with tools. It has four subcommands; `respond` is the
default, so `daimon "<prompt>"` works.

## Subcommands

### `daimon respond [<prompt>]` (default)

One prompt in, one reply out. The prompt is read from stdin when omitted.

| Flag | Meaning |
| --- | --- |
| `-i, --instructions <text>` | System instructions for the session. Default: `config.json`, else the built-in default. |
| `--tool <name>` (repeatable) | Enable only these tools. Default: all registered tools. |
| `--stream` / `--no-stream` | Stream the reply as it is generated (default on). |
| `--unsafe` | Disable the `run_command` policy and sandbox (warns on stderr). |
| `-m, --model <model>` | `system` (default, on device) or `private-cloud` (Apple Private Cloud Compute; data leaves the Mac, noted on stderr). Defaults to `config.json`. |
| `-y, --yes` | Approve risky commands without asking. Without it, `respond` refuses commands at or above the approval threshold. |

```
daimon "What is the date in Tokyo?"
echo "Summarise this" | daimon --tool current_date
daimon --no-stream --instructions "Answer in French" "How are you?"
```

### `daimon chat`

Interactive session. Lines starting with `/` are commands; anything else goes to the model. Replies stream.

| Flag | Meaning |
| --- | --- |
| `-i, --instructions <text>` | As for `respond`. |
| `--tool <name>` (repeatable) | As for `respond`. |
| `-r, --resume <name>` | Continue a transcript saved under `~/.daimon/transcripts/<name>.json`. |
| `--save <name>` | Save the transcript under this name on exit. Defaults to the resumed name. |
| `--unsafe` | Disable the `run_command` policy and sandbox. |
| `-m, --model <model>` | As for `respond`. |

| Command | Effect |
| --- | --- |
| `/help` | List commands. |
| `/tools` | List the tools the model can call. |
| `/tokens` | Tokens used by the transcript, turns, and how often older turns were dropped. |
| `/save [name]` | Save now; the name is remembered for exit. |
| `/new` | Start over with the same instructions and tools. |
| `/quit`, `/exit`, Ctrl-D | Exit, saving if a name is set. |

When the model wants to run a risky command, chat prints it with the reasons and asks `[y]es / [n]o /
[a]lways this session` on stderr before continuing.

Status lines go to stderr, replies to stdout, so `daimon chat 2>/dev/null` pipes cleanly.

### `daimon tools`

Prints each registered tool as `name<TAB>description`. `--json` prints the full catalogue (description,
JSON Schema arguments, limits, example prompt) and `--markdown` the same as Markdown; these are the texts
served to MCP clients as `daimon://tools` and `daimon://tools.md`. See [tools/](tools/README.md).

### `daimon logs`

Shows the audit log (`~/.daimon/logs/audit.jsonl` and rotated files) as one-line summaries, oldest first.

| Flag | Meaning |
| --- | --- |
| `--session <id>` | Only this session. |
| `--kind <kind>` (repeatable) | Only these kinds, e.g. `tool.call`, `policy.decision`. |
| `--tool <name>` | Only tool events for this tool. |
| `-l, --last <n>` | Only the last n matching events. |
| `--json` | Raw JSON Lines instead of summaries. |

See [logging.md](logging.md) for the event catalogue.

### `daimon doctor`

Checks that this install can work and exits non-zero if anything fails: macOS 27 or later, the on-device
model available, the configured model available when it is not `system`, `/usr/bin/sandbox-exec` present,
`config.json` parses, `~/.daimon` writable. Run it first
when something is wrong. `daimon --version` prints the version.

### `daimon mcp`

Serves the Model Context Protocol over stdio until the client closes the pipe. See [mcp.md](mcp.md).

| Flag | Meaning |
| --- | --- |
| `-i, --instructions <text>` | Default instructions for `respond` threads that supply none. |
| `--unsafe` | Disable the `run_command` policy and sandbox for every call. |
| `-m, --model <model>` | Default model for new threads; callers may override per thread. |
| `-y, --yes` | Approve risky commands without asking the client's user. |

## Home directory and configuration

State lives in `~/.daimon`, or `$DAIMON_HOME` when set. It is created on first use by `chat`; other
subcommands only read from it.

| Path | Contents |
| --- | --- |
| `config.json` | Optional settings, below. |
| `transcripts/<name>.json` | Saved conversations. |
| `logs/audit.jsonl` | The audit log, user-only, rotated by size. See [logging.md](logging.md). |

`config.json` fields, all optional:

| Field | Default | Meaning |
| --- | --- | --- |
| `instructions` | built-in | Default system instructions for new sessions. |
| `model` | `system` | `system` or `private-cloud`. See [ADR 0013](decisions/0013-model-selection.md). |
| `commandTimeoutSeconds` | 60 | Wall-clock limit for `run_command`. |
| `commandMaxOutputBytes` | 4096 | Bytes kept from each of stdout and stderr by `run_command`. |
| `maxThreads` | 32 | Live MCP conversation threads before the least recently used is evicted. |
| `commandPolicy` | see [tools/run_command.md](tools/run_command.md) | Deny/allow patterns and sandbox settings for `run_command`. |
| `audit` | `{ "enabled": true, "maxFileBytes": 10485760, "keepFiles": 5 }` | Audit log switch and rotation. |
| `approval` | `{ "threshold": "moderate", "useModel": true, "timeoutSeconds": 120 }` | When to ask a human before `run_command`, and how long silence is tolerated before it counts as a refusal; see [approval.md](approval.md). |

Environment: `DAIMON_HOME` relocates the directory; `DAIMON_LOG=debug|info|error` mirrors diagnostics to
stderr.

```json
{ "instructions": "You are terse.", "commandTimeoutSeconds": 120 }
```

A malformed file or an invalid `commandPolicy` pattern is an error; a missing file is fine. Unknown fields are
ignored.

## Context window

The model's window is about 4k tokens. When a prompt no longer fits, daimon drops older turns (keeping the
instructions and the last four turns) and retries once. `chat` prints a note when this happens; MCP results
carry `condensed: true`. See [context-management.md](context-management.md).

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Runtime failure, such as the model being unavailable or a malformed `config.json`. |
| 64 | Usage error: bad flags, unknown `--tool`, empty stdin prompt. |

## Requirements

macOS 27 or later. The on-device model must be enabled in System Settings (Apple Intelligence); `fm available`
reports its state.
