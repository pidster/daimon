# Objective

Build a single binary, `daimon`, that is an **on-device, tool-using AI microharness** on top of Apple's
Foundation Models framework. It uses the same system language model that Apple exposes to end users through
the `fm` command family, but adds what `fm` lacks: user-defined tools the model can call.

## Definition

- **On-device**: every inference runs on the local Apple silicon model. No network calls for generation.
- **Tool-using**: the model can request tools by name with typed arguments, the harness executes them, and the
  results feed back into the model's reasoning until it produces an answer.
- **Microharness**: the smallest correct agent loop, not a framework. One session, a registry of tools, a
  CLI. Everything else is deliberately out of scope until a concrete need appears.

It has two faces:

- **CLI**: `daimon "<prompt>"` for a person or script, in the shape of `fm respond`.
- **MCP server**: `daimon mcp` so that other agent harnesses can delegate self-contained work to the
  on-device model: running a build or test, summarising or classifying text, searching documents, and other
  non-complex tasks that suit local processing.

## Success criteria

1. `daimon "<prompt>"` answers using the on-device model and calls registered tools when they help.
2. An MCP client can list daimon's tools, run a command, and run a task on the model, over stdio.
3. Adding a tool is a single Swift type plus one line in the registry; heavier tools are separate binaries
   (Rust where it suits) that the harness describes to the model.
4. The CLI feels familiar to an `fm` user: the same flag names where the semantics match.
5. The codebase is exemplary: see [engineering.md](engineering.md).

## Non-goals (for now)

- Remote or third-party models.
- MCP transports other than stdio.
- Conversation state across MCP calls; the caller owns the conversation.
- A plugin system, scripting language, or configuration files for tools.
- A GUI.

## Platform

macOS 27 or later, Xcode 27 or later. See [ADR 0002](decisions/0002-macos-27-baseline.md).
