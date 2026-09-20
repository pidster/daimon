# CLAUDE.md

This file is what Claude Code reads. The instructions shared by every agent working in this repository
(Claude Code, Codex, others) live in `AGENTS.md`, imported here; do not duplicate them in this file. Add
Claude Code-only guidance below the import, and harness-neutral guidance to `AGENTS.md`.

@AGENTS.md

## Claude Code only

- `.claude/rules/*.md` load automatically by path; nothing to do.
- `.claude/settings.json` enables the official `swift-lsp` (SourceKit-LSP, from the Xcode toolchain) and
  `rust-analyzer-lsp` plugins at project scope, so Claude Code has language-server navigation and
  diagnostics for both languages. The binaries are not installed by the plugin: `sourcekit-lsp` comes
  with Xcode (`xcrun --find sourcekit-lsp`) and `rust-analyzer` from `rustup component add rust-analyzer`
  or Homebrew. A fresh clone needs both on `PATH` and a restart of Claude Code; `/plugin` shows errors.
- daimon's tools are `mcp__daimon__respond` and `mcp__daimon__close_thread`; its resources are read with
  the MCP resource tools. If the session starts with the `daimon` server failed to connect, follow the
  release-build note in `AGENTS.md` and then `/mcp`.
- `/mcp reconnect daimon` clears a stuck approval dialog; retry the turn afterwards.
- Use `AskUserQuestion` when a decision is the user's to make. It is Claude Code's dialog; daimon's own
  approval dialog is MCP elicitation, which the harness renders and Claude never sees.
