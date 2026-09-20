# ADR 0022: A caller's JSON Schema shapes the reply through guided generation

Date: 2026-09-20. Status: accepted.

## Context

A harness that delegates classification, extraction, or triage to daimon wants the answer as data it
can branch on, not prose it must parse. The framework has guided generation: a `GenerationSchema`
constrains decoding so the output is JSON of the declared shape, and every backend either declares
the capability (`system`, `private-cloud`, Ollama `completion` models through the chat API's `format`,
Core AI engines that support it) or does not. Callers speak JSON Schema, not the framework's
`@Generable` types, and the schema is only known at call time.

Options for the schema language: accept any JSON Schema and fail late when the framework cannot express
it; accept a subset and refuse the rest by name before generation; or invent a daimon-specific shape.

## Decision

`respond` (MCP) and `daimon respond --schema <path>` (CLI) take a JSON Schema and return JSON of that
shape. `OutputSchema` converts an accepted subset to a `DynamicGenerationSchema` and refuses anything
outside it by construct name and path before generation: objects with typed properties and `required`,
strings with `enum`, integers, numbers, booleans, arrays of one item type with bounds, nesting, and
`description` passed to the model. `$ref`, combinators, patterns, formats, `additionalProperties`, and
type lists are refused. The model must declare guided generation (`ResolvedModel.checkGuidedGeneration`)
or the call is refused with a hint for the declaring source, before any token is generated. The schema
applies to one call, not the thread. The `prompt` audit event carries the schema; the reply's JSON is
the `response` text and is parsed into `structuredContent.output` for the MCP caller.

## Consequences

- A caller gets data that parses and has the declared properties; the subset is documented in one
  table (`docs/mcp.md`) and a refusal names exactly what to remove.
- Small models fill small schemas; the subset excludes what the framework cannot constrain and what a
  4k-token model cannot follow. Widening it is a change to `OutputSchema` and the table, no ADR.
- Streaming is not offered for shaped replies on the CLI: the value is the whole document.
- Measured on this Mac on 2026-09-20 with `--no-tools`: the system model and `ollama:qwen3-coder`
  returned valid JSON for a three-property schema with an enum, a number, and a bounded array.
- Tests: conversion and refusals (`OutputSchemaTests`), the agent path over a scripted model including
  the capability refusal for every declaring source, the request decoding, and the shape over the wire.
