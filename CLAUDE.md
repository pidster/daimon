# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Objective

Build a single binary, `daimon`: an on-device, tool-using AI microharness on top of Apple's Foundation Models framework, the same system model that the `fm` CLI (`/usr/bin/fm`, "Apple Foundation Models CLI") exposes to users.

## Language decision: Swift, linking FoundationModels.framework directly

Swift is the only viable choice for a tool-using harness, verified on this machine (macOS 27.0, Swift 6.4):

- The `fm` CLI cannot drive user-defined tools. `fm respond` and `fm chat` accept `--tool` only for the built-ins `barcode` and `ocr`.
- `fm serve` (Chat Completions API on `/v1/chat/completions`) silently ignores the `tools` parameter. The model narrates wanting to call the tool instead of returning `tool_calls`. It also streams SSE even without `"stream": true`.
- The framework's native `Tool` protocol with `@Generable` arguments works: a probe with `LanguageModelSession(tools: [...])` had the model call the tool and fold the result into its reply.

So `daimon` must link `FoundationModels` and implement the agent loop with `LanguageModelSession`, `Tool`, and `@Generable`, not shell out to `fm`. `fm` remains useful as a reference for CLI ergonomics (`respond`, `chat`, `--instructions`, `--schema`, `--resume`/`--save-transcript`, `count-tokens`, `~/.fm/sessions/`) and for quick manual checks such as `fm available`.

## Toolchain

Xcode 27.0 is the active developer directory (`xcode-select -p` shows `/Applications/Xcode.app/Contents/Developer`) and its license is accepted. Plain `swiftc`/`swift build` work, including the `@Generable` macro. Do not switch to the Command Line Tools: they ship `FoundationModels.framework` but not the `FoundationModelsMacros` plugin, so `@Generable` fails to compile there.

`@Generable` and `LanguageModelSession` require `macOS 26.0` availability; set the package platform accordingly.

## Build and test

```
swift build                                   # debug build -> .build/debug/daimon
swift build -c release                        # release build -> .build/release/daimon
swift test                                    # all tests (swift-testing)
swift test --filter CurrentDateToolTests      # one suite
swift test --filter CurrentDateToolTests/formatsInRequestedZone   # one test
.build/debug/daimon tools                     # list registered tools
.build/debug/daimon "What is the date in Tokyo?"   # live model smoke test
```

Tests must not need the model. Keep model-dependent behaviour behind pure helpers (for example `CurrentDateTool.format`) and test those; the live model is exercised by running the binary.

## Architecture

- `Sources/DaimonCore` is the library and holds everything but argument parsing.
  - `Agent` wraps one `LanguageModelSession`. The framework runs the tool-call loop itself: the model asks for a tool, the session invokes the matching `Tool`, and the result is fed back until the model produces text. `Agent` only checks availability, forwards the prompt, and exposes `respond` (whole reply) and `stream` (delta callback).
  - `ToolRegistry.all` is the single list of tools the model can see. Add a tool by conforming to `FoundationModels.Tool` under `Tools/` with an `@Generable` `Arguments` type and appending it here; the CLI `--tool` flag selects from this list by `name`.
- `Sources/daimon` is a thin swift-argument-parser CLI. `respond` is the default subcommand and mirrors `fm respond` flags (`--instructions`, `--[no-]stream`, `--tool`, stdin prompt); `tools` lists the registry.
- Swift 6 strict concurrency is on. Do not wrap the session in a detached `Task` or `AsyncThrowingStream` closure; the session is not `Sendable`, so keep streaming as a callback on the calling task.

## MCP servers

`.mcp.json` registers a `codex` server (`codex mcp-server`), exposing the OpenAI Codex CLI as MCP tools. It requires the `codex` CLI on `PATH` (installed via Homebrew on this machine).
