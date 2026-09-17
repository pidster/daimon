# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`daimon` is a single Swift binary: an on-device, tool-using AI microharness over Apple's Foundation Models
framework, the same system model the `fm` CLI exposes. Full documentation lives in `docs/`; read
`docs/README.md` first. Key facts:

- Swift, linking `FoundationModels` directly, because `fm` cannot drive user-defined tools
  (`docs/decisions/0001-swift-and-foundationmodels.md`).
- Platform floor is macOS 27, written `.macOS("27.0")` in Package.swift; requires Xcode 27, not just the
  Command Line Tools, for the `@Generable` macro plugin (`docs/decisions/0002-macos-27-baseline.md`).
- Swift 6 strict concurrency is on; streaming is a callback, never a detached task
  (`docs/decisions/0003-callback-streaming.md`). `Agent`'s async methods are `nonisolated(nonsending)` so
  actors can own an `Agent` (`docs/decisions/0007-conversation-threads.md`).

## Commands

Layout: `harness/` is the Swift package (the `daimon` binary); `tools/` is a Cargo workspace for Rust tool
binaries; `docs/` is the documentation; `scripts/check` is the quality gate. Swift commands run inside
`harness/`, Rust commands inside `tools/`.

```
scripts/check install-hooks                   # once per clone: enables the pre-commit gate
scripts/check                                 # hygiene + lint + warnings-as-errors build + tests, both toolchains
scripts/check format                          # auto-fix swift-format and rustfmt findings
cd harness && swift build                     # -> harness/.build/debug/daimon
cd harness && swift test --filter CurrentDateToolTests/formatsInRequestedZone   # one Swift test
cd tools && cargo test -p <crate>             # one Rust crate's tests
harness/.build/debug/daimon tools             # list registered tools
harness/.build/debug/daimon "What is the date in Tokyo?"   # live model smoke test
harness/.build/debug/daimon chat               # REPL; /help lists commands; --resume/--save use ~/.daimon/transcripts
harness/.build/debug/daimon mcp               # MCP server on stdio (stdout is the protocol channel)
scripts/check coverage                        # per-file line coverage (not in the gate)
```

Set `DAIMON_HOME` to a scratch directory when smoke-testing so nothing lands in the real `~/.daimon`.

To smoke-test MCP by hand, pipe JSON-RPC lines into `daimon mcp` and keep stdin open (append `; sleep 5` in
the producing subshell); the server exits on EOF.

## Architecture

See `docs/design.md`. In one paragraph: `harness/Sources/DaimonCore` holds `Agent` (wraps one
`LanguageModelSession`; the framework runs the tool loop), `ToolRegistry.all` (the single list of tools the
model can see), `CommandRunner` (bounded, timed shell execution), `FileReader` (paged, streamed file reads),
`Home`/`Config`/`TranscriptStore` (`~/.daimon` state), `ContextPolicy` and `Transcript.condensed` (overflow
recovery, ADR 0008), and tool types under `Tools/` including `run_command` and `read_file`. `harness/Sources/DaimonMCP` exposes `respond`, `run_command`, and `close_thread` over stdio MCP via the
official Swift SDK; `ToolCatalog` is the contract clients see, and `ThreadStore`/`ConversationThread` (actors)
keep per-`thread_id` conversations (ADR 0007). `harness/Sources/daimon` is a thin swift-argument-parser
CLI mirroring `fm respond` flags plus `mcp`. To add an in-process tool: conform to `FoundationModels.Tool` with
`@Generable` `Arguments`, append to the registry, and test its pure helper. Heavier tools are plain binaries
(Rust under `tools/`) that the harness describes to the model (ADR 0005).

`run_command` is unsandboxed by design (ADR 0005); do not add a sandbox or allowlist without an ADR.
`docs/policy-and-sandboxing.md` holds the investigated options. Context overflow is recovered by dropping old
turns (ADR 0008); `docs/context-management.md` has the rules every tool must follow (bounded output, paging).

## Standards

This project is held to the highest standard of engineering practice; `docs/engineering.md` is the rulebook
and `scripts/check` enforces it. **Definition of done: a change is not done until it is tested, documented
in code, and documented in `docs/`** (tool page, `daimon.md`, `mcp.md`, `design.md`, or an ADR as
appropriate). Update docs in the same commit as the code, not afterwards; if no doc needs changing, say so in
the commit message. Before every commit run `scripts/check` (the hook does this). CI is disabled until a macOS 27 runner is
provisioned, so the hook is the only automated gate. Tests never
need the model. Errors are typed. No force unwrap, force try, `fatalError` in library code, or concurrency
escape hatches. Record non-obvious or hard-to-reverse choices as an ADR in `docs/decisions/`.

Do not pass an explicit `user.email` to git; the configured noreply identity is required for GitHub to accept
pushes.

## MCP servers

`.mcp.json` registers a `codex` server (`codex mcp-server`), exposing the OpenAI Codex CLI as MCP tools. It
requires the `codex` CLI on `PATH`.
