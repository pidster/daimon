# Changelog

Notable changes per release, written for people who run daimon. The release script publishes the
section for the version being cut as the GitHub release notes and refuses to release without one.
Keep an `Unreleased` section at the top while working; the version-bump commit renames it.

## Unreleased

Added:

- `respond` results carry a `receipt`: the turn's tool calls with arguments and result sizes, commands
  with exit status, policy denials, approval decisions, and errors, folded from the thread's audit
  events so a calling harness can verify delegated work without reading the log.

Fixed:

- `--model private-cloud` failed after the request with an opaque `ModelManagerError` 1046. Private
  Cloud Compute needs the managed `com.apple.developer.private-cloud-compute` entitlement, which an
  ad-hoc signed command-line tool cannot carry; daimon now checks its own signature and refuses the
  model with a sentence before anything is sent. `daimon models` shows the same reason.

## 0.2.0

Added:

- Model backends are a registry: `--model <backend>:<name>` names a local runtime by scheme, `daimon
  models` lists every backend's models with their declared capabilities, and a backend this build lacks
  is a clear error. Ollama now reports each model's real capabilities from its `/api/show`, so an
  embedding model is refused for tool use before generation rather than failing during it.
- `--no-tools` on the CLI and `tools: []` over MCP open a text-only conversation, which any model can
  run; a request that needs tool calling on a model that does not declare it is refused with a hint.
- The audit log records `model.resolved` when a conversation opens: backend, model, asset, declared
  capabilities and who declared them, and the tools in use.
- Core AI: `--model coreai:<bundle>` runs a model exported to Apple's Core AI format, in daimon's own
  process, through the bridge from `apple/coreai-models`. Bundles live under `<home>/models/coreai`
  (`config.json` `coreai.modelsDirectory`) or are named by path; `daimon models` lists them with kind,
  compression, source, and size; a missing bundle is refused with where daimon looked and the export
  command. Capabilities come from the bundle. See `docs/backends.md`.

- `inspect`, a read-only tool the model can call to see daimon's effective config, this conversation's
  status, the standing approvals, or recent audit events, bounded to 4 KiB.
- MCP resources `daimon://config`, `daimon://status`, `daimon://approvals`, `daimon://audit`, and the
  template `daimon://audit/{session}` for one thread's events, so a calling harness can read daimon's
  state without a model turn.
- `daimon config` prints the effective configuration as JSON.

- MLX Swift: `--model mlx:<directory>` runs a model in MLX or Hugging Face safetensors layout in
  daimon's process through `mlx-swift-lm`'s bridge, in builds made with `--traits MLX` (the release
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
  with `DAIMON_COREML_MODEL=<path> scripts/check eval` before relying on it.

Changed:

- The `run_command` sandbox also allows writes under the per-user cache directory
  (`getconf DARWIN_USER_CACHE_DIR`), where Clang keeps its module cache; a build that compiles a C
  module inside the sandbox (SwiftPM compiling a dependency's manifest, say) used to fail with "could
  not build Objective-C module 'Darwin'".
- `daimon` with no prompt on a terminal prints its help instead of waiting silently for stdin; a piped
  stdin is still read.

## 0.1.5

Fixed:

- Codex could not connect: its `initialize` carries `capabilities.experimental` with object values,
  which the MCP specification allows, and the Swift SDK rejected the whole request with `-32603`. daimon
  now normalises such messages before the SDK decodes them. daimon never reads the field; no client
  feature is enabled by it. The captured request is a regression test.

## 0.1.4

Added:

- Three-layer instructions: daimon's own system prompt (a text file in the source tree, embedded at build
  time), the operator's `systemPromptExtension` in `config.json`, and the caller's `--instructions` or MCP
  `instructions`, rendered in that order. A caller can no longer replace daimon's framing. The old config
  key `instructions` is still read as the extension.
- The audit `session.start` event records the extension and the caller's instructions separately.
- `daimon mcp --tool` selects the tools threads get unless a `respond` call names its own.

Changed:

- Releases run the full test suite and a coverage gate; line coverage must not fall below the recorded
  baseline.
- `--resume` of a missing or invalid transcript name is a usage error (exit 64), like other bad inputs.

## 0.1.3

Added:

- Run sessions on a local Ollama model with `--model ollama:<name>`, in `config.json`, or per MCP thread.
  `daimon models` lists Apple's two models with availability and every model Ollama serves. New `ollama`
  config section for the server address and per-request timeout; `daimon doctor` checks the configured
  model resolves.
- Approvals have four scopes: this turn, this session, this project (30 days, this directory), always
  (30 days). Project and always approvals persist under `~/.daimon/approvals.json`; `daimon approvals`
  lists, revokes, and clears them. Dangerous commands are never persisted.
- Each simple command in a line (`a && b | c`) is checked and approved on its own and remembered by its
  program, so `head -n 5 x` is remembered as `head *`.
- A once-approval covers the rest of the turn, however many commands the model runs.
- The MCP `respond` result reports `refusals`: commands the gate refused this turn, with reasons.
- A bare `exit`, `quit`, or `q` ends `daimon chat`.

Changed:

- The approval threshold is `safe`, `moderate`, `dangerous`, or `never`; the on-device classifier runs
  only when the rules did not decide.
- Every face of daimon (`respond`, `chat`, `mcp`) shares one set-up path and one approval store, so a
  "this project" answer given over MCP is written once and honoured everywhere.

Fixed:

- "This project" approvals given over MCP were not being persisted.
- Partial `commandPolicy` objects in `config.json` keep every other default.

## 0.1.2 and earlier

See the GitHub releases for 0.1.0 to 0.1.2: the first Homebrew releases, with the sandboxed
`run_command`, `read_file`, `current_date`, the audit log, the risk classifier and approval gate, the MCP
server with per-thread conversations, and model selection between `system` and `private-cloud`.
