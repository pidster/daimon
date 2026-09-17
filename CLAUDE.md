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
  (`docs/decisions/0003-callback-streaming.md`).

## Commands

```
scripts/check install-hooks                   # once per clone: enables the pre-commit gate
scripts/check                                 # hygiene + lint + warnings-as-errors build + tests
scripts/check lint                            # swift format lint --strict
swift format --in-place --recursive Sources Tests Package.swift   # auto-fix formatting
swift build                                   # -> .build/debug/daimon
swift test --filter CurrentDateToolTests/formatsInRequestedZone   # one test
.build/debug/daimon tools                     # list registered tools
.build/debug/daimon "What is the date in Tokyo?"   # live model smoke test
```

## Architecture

See `docs/design.md`. In one paragraph: `Sources/DaimonCore` holds `Agent` (wraps one `LanguageModelSession`;
the framework runs the tool loop), `ToolRegistry.all` (the single list of tools the model can see), and tool
types under `Tools/`. `Sources/daimon` is a thin swift-argument-parser CLI mirroring `fm respond` flags.
To add a tool: conform to `FoundationModels.Tool` with `@Generable` `Arguments`, append to the registry, and
test its pure helper.

## Standards

This project is held to the highest standard of engineering practice; `docs/engineering.md` is the rulebook
and `scripts/check` enforces it. Before every commit run `scripts/check` (the hook does this). CI is disabled until a macOS 27 runner is
provisioned, so the hook is the only automated gate. Tests never
need the model. Errors are typed. No force unwrap, force try, `fatalError` in library code, or concurrency
escape hatches. Record non-obvious or hard-to-reverse choices as an ADR in `docs/decisions/`.

Do not pass an explicit `user.email` to git; the configured noreply identity is required for GitHub to accept
pushes.

## MCP servers

`.mcp.json` registers a `codex` server (`codex mcp-server`), exposing the OpenAI Codex CLI as MCP tools. It
requires the `codex` CLI on `PATH`.
