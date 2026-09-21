# ADR 0001: Implement wisp in Swift, linking FoundationModels directly

Date: 2026-09-17. Status: accepted.

## Context

The project brief allows any language. The requirement is a tool-using harness over the on-device Apple
model. Two integration routes exist: wrap the `fm` CLI or its `fm serve` HTTP API from any language, or link
`FoundationModels.framework` from Swift.

Verified on macOS 27.0 with Xcode 27.0 (see [fm-cli.md](../fm-cli.md)):

- `fm respond`/`fm chat` accept `--tool` only for built-ins (`barcode`, `ocr`).
- `fm serve` ignores the `tools` parameter and never returns `tool_calls`.
- A Swift probe using `LanguageModelSession(tools:)` with a `Tool` whose `Arguments` are `@Generable` had the
  model call the tool and use its result.

## Decision

Swift, linking `FoundationModels` directly. The framework's `Tool` protocol and `@Generable` macro are the
only supported path to user-defined tool calling.

## Consequences

- The project is macOS-only, which the objective already required.
- Xcode (not just the Command Line Tools) is required to build, because the `FoundationModelsMacros` plugin
  ships only with Xcode.
- A hand-rolled tool loop over `fm respond --schema` was rejected: it would re-implement what the framework
  already does, with worse reliability.
