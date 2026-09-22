# wisp command reference

`wisp` runs Apple's on-device Foundation Model with tools. It has six subcommands (`respond`, `chat`,
`tools`, `logs`, `doctor`, `mcp`); `respond` is the default, so `wisp "<prompt>"` works.

## Subcommands

### `wisp respond [<prompt>]` (default)

One prompt in, one reply out. The prompt is read from stdin when omitted and stdin is a pipe; on a
terminal with no prompt, `wisp` prints its help instead of waiting for input.

| Flag | Meaning |
| --- | --- |
| `-i, --instructions <text>` | Instructions for this conversation, added under wisp's own system prompt and `config.json`'s `systemPromptExtension`. See [ADR 0017](decisions/0017-three-layer-instructions.md). |
| `--tool <name>` (repeatable) | Enable only these tools. Default: all registered tools. |
| `--no-tools` | Give the model no tools: a text-only conversation, which a model that declares no tool calling can still run. |
| `--stream` / `--no-stream` | Stream the reply as it is generated (default on). |
| `--unsafe` | Disable the `run_command` policy and sandbox (warns on stderr). |
| `-m, --model <model>` | `system` (default, on device), `private-cloud` (alias `pcc`; Apple Private Cloud Compute; data leaves the Mac, noted on stderr), or `<backend>:<name>` for a local runtime (`ollama:qwen3-coder`; `wisp models` lists every backend's models). A request that needs tool calling is refused before generation when the model does not declare it; see [ADR 0019](decisions/0019-model-backends.md). Defaults to `config.json`. |
| `-y, --yes` | Approve risky commands without asking. Without it, `respond` refuses commands at or above the approval threshold. |
| `--schema <path>` | A JSON Schema file; the reply is JSON of that shape through guided generation, printed whole (not streamed). The accepted subset and the capability rule are in [mcp.md](mcp.md), "Structured output". |

```
wisp "What is the date in Tokyo?"
echo "Summarise this" | wisp --tool current_date
wisp --no-stream --instructions "Answer in French" "How are you?"
wisp --no-tools --schema verdict.json "Which language is this: fn main() {}"
```

### `wisp chat`

Interactive session. Lines starting with `/` are commands; anything else goes to the model. Replies stream.

What a session shows, and where it goes:

- A banner with the version, model, tool count, and audit session, then a status line above every
  prompt: model, directory, git branch and whether tracked files have changes, the approval mode
  (`approve at moderate`, `never asks`, `--yes`), and `context N% used` when the model's window and the
  transcript's size are both known. Each part is omitted when unknown; `GitState` reads the branch from
  `.git/HEAD` and the state from `git status --porcelain` with a two-second cap.
- The model's tool activity as it happens, one dim line per call and result, from the same events the
  audit log records: `⚙ run_command git status`, then `↳ exit 0`; `⚙ read_file README.md`, then
  `↳ 2048 bytes in 0.0 s: 1\t# wisp`. `/last` prints the last tool result whole.
- Replies on stdout; everything else (banner, status, prompt, tool lines, notes, approval dialogs) on
  stderr, so `wisp chat > transcript.txt` captures only the replies.
- Colour and weight when stdout is a terminal: the prompt and model in cyan, notes and tool lines dim,
  approvals yellow with the level coloured, errors red. Off when piped, when `NO_COLOR` is set, or when
  `TERM` is `dumb`.

| Flag | Meaning |
| --- | --- |
| `-i, --instructions <text>` | As for `respond`. |
| `--tool <name>` (repeatable) | As for `respond`. |
| `-r, --resume <name>` | Continue a transcript saved under `~/.wisp/transcripts/<name>.json`. |
| `--save <name>` | Save the transcript under this name on exit. Defaults to the resumed name. |
| `--list` | Print the names of saved transcripts and exit. |
| `--unsafe` | Disable the `run_command` policy and sandbox. |
| `-m, --model <model>` | As for `respond`. |
| `-y, --yes` | Approve risky commands without asking; the status line says `--yes`. |

| Command | Effect |
| --- | --- |
| `/help` | List commands. |
| `/tools` | List the tools the model can call. |
| `/tokens` | Tokens used by the transcript, turns, and how often older turns were dropped. |
| `/inspect [what]`, `/status` | wisp's own `config`, `status` (default), `approvals`, or `audit`, as the model's `inspect` tool shows them. |
| `/last` | The last tool result in full; the live line shows only its first line. |
| `/save [name]` | Save now; the name is remembered for exit. |
| `/new` | Start over with the same instructions and tools. |
| `/quit`, `/exit`, `/q`, a bare `exit`, `quit`, or `q`, Ctrl-D | Exit, saving if a name is set. |
| `/help`, `/?`, a bare `help` | List commands. |

When the model wants to run a risky command, chat asks on stderr with a compact dialog: the level and
command, the whole line when the command is one part of it, the directory, each reason on a line
(shortened to 110 characters), the pattern the answer is remembered under, and one key line:
`[y]once [s]ession [p]roject 30d [a]lways 30d [n]o`. `y` approves it for the rest of this turn, `s`
for the session, `p` for this project (30 days, this directory), `a` always (30 days, anywhere); `n`, an
empty answer, or end of input refuses it ([approval.md](approval.md)).

Status lines and the `> ` prompt go to stderr, replies to stdout, so `wisp chat 2>/dev/null` prints only
what the model said. A *turn* is one message from you and everything the model does to answer it.

### Headless chat: `wisp chat --json`

`--json` replaces the terminal with JSON Lines on stdin and stdout so another program can be the face
while the session, tools, gate, and audit stay in this process. The `wisp-tui` front end in `tools/`
drives it (spike, 2026-09-22; the shape may change). One object per line, `type` names it.

Out, to the front end:

| `type` | Fields | When |
| --- | --- | --- |
| `note` | `text` | The banner, the help line, and anything chat would say on stderr. |
| `status` | `model`, `directory`, `branch`, `dirty`, `approval`, `contextUsed` (nulls when unknown) | Before each prompt: the turn is over and input is wanted. |
| `delta` | `text` | A fragment of the streamed reply. |
| `output` | `text` | A whole line, as `/help` or `/last` print; an empty one ends a reply. |
| `event` | `kind`, `call`, `turn`, `details` | Every audit event of the conversation, as `logging.md` describes them; the front end chooses what to show. |
| `approval` | `id`, `command`, `line`, `pattern`, `directory`, `level`, `reasons` | A command needs a decision; answer with the `id` within `approval.timeoutSeconds` or it is refused. |
| `exit` | | The loop has ended. |

In, from the front end: `{"type":"message","text":"…"}` for a chat line, slash commands included, and
`{"type":"answer","id":"…","decision":"once|session|project|always|no"}` for an approval. A line that
is not a JSON object is taken as a message, so the protocol can be driven by hand:

```
printf 'What is the date in Tokyo?\n/quit\n' | wisp chat --json
```

Everything else about the session is as for the terminal chat: the same flags, transcripts, and audit.
Only the presentation moves out of the process.

### `wisp tools`

Prints each registered tool as `name<TAB>description`. `--json` prints the full catalogue (description,
JSON Schema arguments, limits, example prompt) and `--markdown` the same as Markdown; these are the texts
served to MCP clients as `wisp://tools` and `wisp://tools.md`. See [tools/](tools/README.md).

### `wisp logs`

Shows the audit log (`~/.wisp/logs/audit.jsonl` and rotated files) as one-line summaries, oldest first.

| Flag | Meaning |
| --- | --- |
| `--session <id>` | Only this session. |
| `--kind <kind>` (repeatable) | Only these kinds, e.g. `tool.call`, `policy.decision`. |
| `--tool <name>` | Only tool events for this tool. |
| `-l, --last <n>` | Only the last n matching events. |
| `--json` | Raw JSON Lines instead of summaries. |

See [logging.md](logging.md) for the event catalogue.

### `wisp models`

Lists what `--model` and `config.json` can name: `system` and `private-cloud` with their availability and
declared capabilities as the framework reports them, then every model each local backend serves (Ollama
from its `/api/tags`, with parameter count and size). The configured default is marked with `*`. A
backend that does not answer gets one line saying so; the others are still listed.

```
* system	available; toolCalling, guidedGeneration, vision
  private-cloud	unavailable: model 'private-cloud' is unavailable: this binary lacks the com.apple.developer.private-cloud-compute entitlement, …
  ollama:qwen3-coder:latest	30.5B 18.6 GB
```

`private-cloud` is refused from every unsigned build; see [backends.md](backends.md), "Private Cloud
Compute".

`wisp tools --markdown` and `--json` include a `Measured:` line, or a `measurements` field, for each
tool the eval harness has measured ([measurements.md](measurements.md)).

### `wisp config`

Prints the effective configuration as JSON: every setting with its default applied, the model, the
`run_command` policy, and the paths under `~/.wisp`, with whether `config.json` exists. The same view
the model's [`inspect`](tools/inspect.md) tool and the `wisp://config` resource give.

### `wisp doctor`

Checks that this install can work and exits non-zero if anything fails: macOS 27 or later, the on-device
model available, the configured model available when it is not `system` (for `ollama:<name>`, that the
server answers and lists the model), `/usr/bin/sandbox-exec` present,
`config.json` parses, `~/.wisp` writable. Run it first
when something is wrong. `wisp --version` prints the version.

### `wisp approvals`

`wisp approvals` (or `approvals list`) prints standing approvals: id, scope, expiry, directory, pattern
(such as `head *`).
`wisp approvals revoke <id>` removes one; `wisp approvals clear` removes all. See
[approval.md](approval.md).

### `wisp mcp`

Serves the Model Context Protocol over stdio until the client closes the pipe. See [mcp.md](mcp.md).

| Flag | Meaning |
| --- | --- |
| `-i, --instructions <text>` | Conversation instructions for threads whose `respond` call supplies none. |
| `--tool <name>` (repeatable) | Tools threads get unless a `respond` call names its own. Default: all. |
| `--unsafe` | Disable the `run_command` policy and sandbox for every call. |
| `-m, --model <model>` | Default model for new threads; callers may override per thread. |
| `-y, --yes` | Approve risky commands without asking the client's user. |

## Home directory and configuration

State lives in `~/.wisp`, or `$WISP_HOME` when set. Any command that writes there creates it: `respond`,
`chat`, and `mcp` write the audit log (unless `audit.enabled` is false), `chat` writes transcripts, and
`doctor` probes that it is writable. `tools` and `logs` never create it.

| Path | Contents |
| --- | --- |
| `config.json` | Optional settings, below. |
| `transcripts/<name>.json` | Saved conversations. |
| `approvals.json` | Standing command approvals (`project` and `always` scopes), user-only. |
| `logs/audit.jsonl` | The audit log, user-only, rotated by size. See [logging.md](logging.md). |

`config.json` fields, all optional:

| Field | Default | Meaning |
| --- | --- | --- |
| `systemPromptExtension` | none | Text added under wisp's own system prompt for every session and thread on this Mac: house style, standing assumptions. `instructions` is the pre-0.2 name and is read when this key is absent. See [ADR 0017](decisions/0017-three-layer-instructions.md). |
| `model` | `system` | `system`, `private-cloud`, or `ollama:<name>`. See [ADR 0013](decisions/0013-model-selection.md) and [ADR 0016](decisions/0016-local-runtimes-through-an-executor.md). |
| `ollama` | `{ "baseURL": "http://127.0.0.1:11434", "timeoutSeconds": 120, "contextLength": 8192 }` | Where Ollama serves `ollama:<name>` models, how long one generation request may take, and the context window asked of the server on every request (`num_ctx`), which wisp condenses against. See [backends.md](backends.md). |
| `coreai` | `{ "modelsDirectory": "<home>/models/coreai" }` | Where exported Core AI bundles live for `coreai:<name>` models. See [backends.md](backends.md). |
| `mlx` | `{ "modelsDirectory": "<home>/models/mlx", "models": {} }` | Where MLX model directories live for `mlx:<name>` models, and per model the capabilities the operator declares (`toolCalling`, `guidedGeneration`, `reasoning`, `vision`). Needs a build with `--traits MLX`. See [backends.md](backends.md). |
| `commandTimeoutSeconds` | 60 | Wall-clock limit for `run_command`. |
| `commandMaxOutputBytes` | 4096 | Bytes kept from each of stdout and stderr by `run_command`. |
| `maxThreads` | 32 | Live MCP conversation threads before the least recently used is evicted. |
| `commandPolicy` | see [tools/run_command.md](tools/run_command.md) | Deny/allow patterns and sandbox settings for `run_command`. Partial objects are fine: `{"commandPolicy":{"sandbox":{"allowNetwork":false}}}` keeps every other default. |
| `audit` | `{ "enabled": true, "maxFileBytes": 10485760, "keepFiles": 5 }` | Audit log switch and rotation. |
| `approval` | `{ "threshold": "moderate", "classifier": "system-model", "timeoutSeconds": 600, "persistDays": 30 }` | When to ask a human before `run_command`, which classifier judges commands (`rules`, `system-model`, or `coreml` with `coremlModel` and `coremlMinimumConfidence`), how long silence is tolerated before it counts as a refusal (`0` waits forever), and how long persisted approvals last; see [approval.md](approval.md). |

Environment: `WISP_HOME` relocates the directory; `WISP_LOG=debug|info|error` mirrors diagnostics to
stderr.

```json
{ "systemPromptExtension": "Prefer British spelling.", "commandTimeoutSeconds": 120 }
```

A malformed file or an invalid `commandPolicy` pattern is an error; a missing file is fine. Unknown fields are
ignored.

## Context window

The model's window is about 4k tokens. When a prompt no longer fits, wisp drops older turns (keeping the
instructions and the last four turns) and retries once. `chat` prints a note when this happens; MCP results
carry `condensed: true`. See [context-management.md](context-management.md).

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, including a reply in which the model reports that a command was refused; the refusal itself is in the audit log (`wisp logs --kind approval.decided`). |
| 1 | Runtime failure, such as the model being unavailable. |
| 64 | Usage error: bad flags, unknown `--tool` or `--model`, empty stdin prompt, malformed `config.json`, a `--resume` name that is invalid or not saved. |

## Requirements

macOS 27 or later. The on-device model must be enabled in System Settings (Apple Intelligence); `fm available`
reports its state.
