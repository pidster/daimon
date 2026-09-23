# Changelog

Notable changes per release, written for people who run wisp. The release script publishes the
section for the version being cut as the GitHub release notes and refuses to release without one.
Keep an `Unreleased` section at the top while working; the version-bump commit renames it.

## Unreleased

Changed:

- `wisp models` and `/models` list only the models that can serve the conversation: they must resolve
  and, when the conversation has tools, declare tool calling. `--all` adds the excluded ones with the
  reason; `--no-tools` judges for a conversation without tools. An Ollama model that cannot hold a
  conversation, such as an embedding model, is refused by `--model` and `/model` with that reason
  instead of failing at the first prompt.

## 0.8.0

Added:

- Notifications: the model's new `notify` tool and `wisp notify <message>` show a macOS notification.
  Text is bounded, at most five a minute (`notifications.perMinute`), `notifications.enabled: false`
  turns them off, and every request is audited as `notification`.

## 0.7.0

Added:

- `/models` and `/model <name>` in chat: list the models this Mac can run and switch the conversation
  to one, keeping the transcript. Works in the plain chat and in `wisp-tui`.

Changed:

- The model introduces itself as Wisp.

## 0.6.1

Fixed:

- `wisp chat` launched through `PATH` did not find `wisp-tui`: it looked beside `argv[0]`, a bare name,
  rather than beside the process's real executable, so the plain chat started instead of the front end.

## 0.6.0

Added:

- `wisp chat --json`, a headless chat speaking JSON Lines, and `wisp-tui`, a Rust front end over it
  that keeps the conversation in the terminal's scrollback above a pinned input and status band. A
  merged from a one-day spike ([ADR 0029](docs/decisions/0029-tui-front-end.md)); the protocol may
  still change. The formula installs both binaries, and `wisp chat` on a terminal hands the session
  to `wisp-tui`; `--plain` keeps the line-based chat.

## 0.5.0

Fixed:

- An unanswered MCP approval now comes back at `approval.timeoutSeconds` as promised. The wait was
  decided at the deadline but not returned until the client eventually answered the dialog, which on
  2026-09-21 took 11 to 56 minutes for three refusals.

Changed:

- `wisp chat` shows its work: a status line above every prompt (model, directory, git branch and state,
  approval mode, context used), the model's tool calls and results live as one dim line each, a compact
  approval dialog with a one-line key, colour on a terminal (off when piped or with `NO_COLOR`), and
  new commands `/inspect`, `/status`, `/last`, plus `--yes`. Replies alone go to stdout, as before.

## 0.4.0

Renamed: daimon is now **wisp**. The binary is `wisp`, the home directory `~/.wisp` (`WISP_HOME`), the
environment variables `WISP_*`, the unified-logging subsystem `com.pidster.wisp`, the MCP server `wisp`
with `wisp://` resources, and a new formula in the Homebrew tap (`brew install pidster/tap/wisp`).
Nothing carries over automatically: move `~/.daimon` to `~/.wisp` yourself if you want your approvals and
transcripts, and `brew uninstall daimon`. The `daimon` formula stays in the tap.

Added:

- `summarise_diff`, a new MCP tool: run a command that prints a diff (or read a diff file) and get back
  a headline, one line per file with its change kind and line counts, and flags for secrets, deleted or
  disabled tests, and binary or generated content. Paths and counts come from the diff itself; the diff
  never leaves the Mac.
- Measurements: `scripts/check eval` records what each delegated task achieved (`triage`,
  `edit_file` replace after read, schema-shaped replies, the risk classifier) into a resource embedded
  in the binary; `wisp tools --markdown`, `wisp://tools`, and the new `wisp://measurements`
  resource publish them so a caller knows what to trust.

Changed:

- Approvals for programs whose first word is the verb (`git`, `cargo`, `swift`, `npm`, `brew`, `docker`
  and others listed in `multiplexers.txt`) are remembered by verb: `git commit *` and `git push *` are
  separate, so a session answer for one no longer covers the other. A standing approval stored under
  the old `git *` still counts until it expires.
- `edit_file` replace takes `line`, the number `read_file` showed, with `content` as the whole new line
  and `find` as an optional check on that line; a drifted number changes nothing. The by-`find` form
  measured 3 of 5, because the model retyped the neighbouring line into `content`.
- Local runtimes that truncate silently no longer lose the instructions: `Agent` condenses the transcript
  ahead of the window when the usage the last reply reported, plus the new prompt, would pass 85% of it,
  audited as `context.condensation` with reason `budget`. Ollama is asked for an explicit window on every
  request (`ollama.contextLength`, default 8192, sent as `num_ctx`), and `/tokens` shows the reported
  usage for models that cannot count.

## 0.3.0

Added:

- `edit_file`, a new model tool: write a whole text file, append to it, or replace one exact
  occurrence of a piece of text. Writes are atomic and confined to the directories the sandbox lets
  commands write under, every edit passes the risk classifier and approval as `edit_file <mode> <path>`, and
  each edit is audited as `file.write` and listed in the receipt's `files`.
- `triage`, a new MCP tool: run a build or test command on this Mac (or read an output file) and get
  back only the failures as `kind`, `location`, `message`, judged chunk by chunk by the on-device model.
  The raw output never leaves the Mac; the command runs under the same policy, sandbox, and approval
  as the model's own `run_command`.
- Structured output: `respond` takes a `schema` (a JSON Schema object in an accepted subset) and
  returns JSON of that shape, parsed into `structuredContent.output`; the CLI takes `--schema <path>`.
  A model that does not declare guided generation is refused before generation.
- `respond` results carry a `receipt`: the turn's tool calls with arguments and result sizes, commands
  with exit status, policy denials, approval decisions, and errors, folded from the thread's audit
  events so a calling harness can verify delegated work without reading the log.

Fixed:

- `--model private-cloud` failed after the request with an opaque `ModelManagerError` 1046. Private
  Cloud Compute needs the managed `com.apple.developer.private-cloud-compute` entitlement, which an
  ad-hoc signed command-line tool cannot carry; wisp now checks its own signature and refuses the
  model with a sentence before anything is sent. `wisp models` shows the same reason.

## 0.2.0

Added:

- Model backends are a registry: `--model <backend>:<name>` names a local runtime by scheme, `wisp
  models` lists every backend's models with their declared capabilities, and a backend this build lacks
  is a clear error. Ollama now reports each model's real capabilities from its `/api/show`, so an
  embedding model is refused for tool use before generation rather than failing during it.
- `--no-tools` on the CLI and `tools: []` over MCP open a text-only conversation, which any model can
  run; a request that needs tool calling on a model that does not declare it is refused with a hint.
- The audit log records `model.resolved` when a conversation opens: backend, model, asset, declared
  capabilities and who declared them, and the tools in use.
- Core AI: `--model coreai:<bundle>` runs a model exported to Apple's Core AI format, in wisp's own
  process, through the bridge from `apple/coreai-models`. Bundles live under `<home>/models/coreai`
  (`config.json` `coreai.modelsDirectory`) or are named by path; `wisp models` lists them with kind,
  compression, source, and size; a missing bundle is refused with where wisp looked and the export
  command. Capabilities come from the bundle. See `docs/backends.md`.

- `inspect`, a read-only tool the model can call to see wisp's effective config, this conversation's
  status, the standing approvals, or recent audit events, bounded to 4 KiB.
- MCP resources `wisp://config`, `wisp://status`, `wisp://approvals`, `wisp://audit`, and the
  template `wisp://audit/{session}` for one thread's events, so a calling harness can read wisp's
  state without a model turn.
- `wisp config` prints the effective configuration as JSON.

- MLX Swift: `--model mlx:<directory>` runs a model in MLX or Hugging Face safetensors layout in
  wisp's process through `mlx-swift-lm`'s bridge, in builds made with `--traits MLX` (the release
  is); a build without the trait refuses `mlx:` models with the reason. Capabilities are declared by the
  operator per model in `config.json`'s `mlx.models`; an undeclared model is text only. Verified with
  `mlx-community/Qwen3-1.7B-4bit`: text replies in 2.5 s including load, and the tool loop 3 of 3 with
  `toolCalling` declared. The Homebrew release does not include MLX, because it needs a Metal library
  bundle beside the binary; build with `--traits MLX` yourself. See `docs/backends.md`.
- `approval.classifier` chooses what judges commands beside the rules: `rules`, `system-model` (the
  default, unchanged), or `coreml`, a Core ML text classifier you train from a `text,label` CSV with
  `scripts/train-risk-classifier`. The model must follow a versioned contract or it is rejected; every
  failure or low-confidence verdict is `moderate` with the reason; the audit records the model's
  identity, version, label, and confidence. Measured on 2026-09-20: a model trained on the 45-command
  eval set scores 45/45 on it (its own training data, so no evidence of judgement); trained on the 35
  non-held-out commands it got 5 of the 10 held-out ones right, and two dangerous commands it called
  `safe` were kept off `safe` only by the confidence guard. Not fit to judge alone; measure your own
  with `WISP_COREML_MODEL=<path> scripts/check eval` before relying on it.

Changed:

- The `run_command` sandbox also allows writes under the per-user cache directory
  (`getconf DARWIN_USER_CACHE_DIR`), where Clang keeps its module cache; a build that compiles a C
  module inside the sandbox (SwiftPM compiling a dependency's manifest, say) used to fail with "could
  not build Objective-C module 'Darwin'".
- `wisp` with no prompt on a terminal prints its help instead of waiting silently for stdin; a piped
  stdin is still read.

## 0.1.5

Fixed:

- Codex could not connect: its `initialize` carries `capabilities.experimental` with object values,
  which the MCP specification allows, and the Swift SDK rejected the whole request with `-32603`. wisp
  now normalises such messages before the SDK decodes them. wisp never reads the field; no client
  feature is enabled by it. The captured request is a regression test.

## 0.1.4

Added:

- Three-layer instructions: wisp's own system prompt (a text file in the source tree, embedded at build
  time), the operator's `systemPromptExtension` in `config.json`, and the caller's `--instructions` or MCP
  `instructions`, rendered in that order. A caller can no longer replace wisp's framing. The old config
  key `instructions` is still read as the extension.
- The audit `session.start` event records the extension and the caller's instructions separately.
- `wisp mcp --tool` selects the tools threads get unless a `respond` call names its own.

Changed:

- Releases run the full test suite and a coverage gate; line coverage must not fall below the recorded
  baseline.
- `--resume` of a missing or invalid transcript name is a usage error (exit 64), like other bad inputs.

## 0.1.3

Added:

- Run sessions on a local Ollama model with `--model ollama:<name>`, in `config.json`, or per MCP thread.
  `wisp models` lists Apple's two models with availability and every model Ollama serves. New `ollama`
  config section for the server address and per-request timeout; `wisp doctor` checks the configured
  model resolves.
- Approvals have four scopes: this turn, this session, this project (30 days, this directory), always
  (30 days). Project and always approvals persist under `~/.wisp/approvals.json`; `wisp approvals`
  lists, revokes, and clears them. Dangerous commands are never persisted.
- Each simple command in a line (`a && b | c`) is checked and approved on its own and remembered by its
  program, so `head -n 5 x` is remembered as `head *`.
- A once-approval covers the rest of the turn, however many commands the model runs.
- The MCP `respond` result reports `refusals`: commands the gate refused this turn, with reasons.
- A bare `exit`, `quit`, or `q` ends `wisp chat`.

Changed:

- The approval threshold is `safe`, `moderate`, `dangerous`, or `never`; the on-device classifier runs
  only when the rules did not decide.
- Every face of wisp (`respond`, `chat`, `mcp`) shares one set-up path and one approval store, so a
  "this project" answer given over MCP is written once and honoured everywhere.

Fixed:

- "This project" approvals given over MCP were not being persisted.
- Partial `commandPolicy` objects in `config.json` keep every other default.

## 0.1.2 and earlier

See the GitHub releases for 0.1.0 to 0.1.2: the first Homebrew releases, with the sandboxed
`run_command`, `read_file`, `current_date`, the audit log, the risk classifier and approval gate, the MCP
server with per-thread conversations, and model selection between `system` and `private-cloud`.
