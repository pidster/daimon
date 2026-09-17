# ADR 0005: Tools are plain binaries; the harness owns the model-facing schema

Date: 2026-09-17. Status: accepted.

## Context

Tools beyond the trivial should be separate binaries, written in Rust where that suits. The question was how
the harness talks to them. One MCP server per tool was considered and rejected: MCP is a boundary between
systems, not a packaging unit for a single function, and it would add a process, a handshake, and schema
translation per tool for no benefit when we control both sides.

## Decision

- A tool binary is an ordinary CLI program: arguments in, stdout out, meaningful exit code. It knows nothing
  about agents or MCP and stays useful on its own.
- The harness declares one Swift `FoundationModels.Tool` per binary. Name, description, and `@Generable`
  arguments live in Swift because that text is prompt material and must be tuned against the on-device model.
- The first tool, `run_command`, is implemented in Swift in-process (`CommandRunner`), because wrapping
  `/bin/sh -c` in a Rust binary would add nothing. It is the generic exec tool in the Claude Code Bash-tool
  shape; other binaries become useful through it before they get a dedicated `Tool`.
- The Cargo workspace under `tools/` is reserved for binaries that do real work (search, indexing, chunked
  summarisation). Rust checks in `scripts/check` activate when the first crate lands.

## Consequences

- `run_command` was initially unsandboxed. Superseded by [ADR 0009](0009-command-policy-and-sandbox.md):
  a `CommandPolicy` with deny/allow patterns and a Seatbelt sandbox now governs it. Callers can still
  restrict exposure with the CLI's `--tool` selection or the MCP `tools` argument.
- Output is bounded (4 KiB per stream by default, tail kept) and commands time out (60 s), because the model's
  context window is small.
- The model can only use a Rust binary well if its Swift `Tool` description explains when to call it; that
  description is part of the tool, not an afterthought.
