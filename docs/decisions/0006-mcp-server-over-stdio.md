# ADR 0006: daimon is an MCP server over stdio

Date: 2026-09-17. Status: accepted.

## Context

Other agent harnesses (Claude Code, Codex, and the like) should be able to delegate self-contained work to the
on-device model: running a build or test, summarising or classifying text, and similar tasks that suit local
processing. MCP is the boundary those harnesses already speak.

## Decision

- `daimon mcp` serves MCP over stdio using the official `modelcontextprotocol/swift-sdk`. No other transport
  for now.
- Two tools are advertised (`DaimonMCP.ToolCatalog`): `respond`, which runs a prompt on the on-device model
  with daimon's registered tools available to it, and `run_command`, which runs a shell command directly
  without the model. Both share `CommandRunner` limits.
- `respond` is stateless: every call gets a fresh `Agent` and session. Conversation continuity across calls is
  not offered; the caller owns the conversation.
- Argument validation errors are MCP protocol errors (`invalidParams`); execution failures, including an
  unavailable model, are tool results with `isError: true`, as the MCP spec prescribes.
- The server exits when stdin reaches EOF. Real clients hold the pipe open for the session's lifetime.

## Consequences

- Stdout is the protocol channel while serving; nothing in the process may print to it. Diagnostics go to
  stderr.
- The tool descriptions tell callers about the roughly 4k-token context window so that a frontier-model client
  delegates appropriately sized tasks.
- The SDK dispatches requests concurrently, so two `respond` calls may run at once, each with its own session.
- The SDK pulls in swift-nio and related packages; build time and binary size grow accordingly. Accepted
  rather than hand-rolling JSON-RPC.
