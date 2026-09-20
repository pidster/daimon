# Changelog

Notable changes per release, written for people who run daimon. The release script publishes the
section for the version being cut as the GitHub release notes and refuses to release without one.
Keep an `Unreleased` section at the top while working; the version-bump commit renames it.

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
