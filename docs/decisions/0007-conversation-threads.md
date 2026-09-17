# ADR 0007: Conversation threads over MCP

Date: 2026-09-17. Status: accepted. Amends ADR 0006 (the "stateless respond" clause).

## Context

An MCP server is spawned once by a client harness and lives for that harness's session, serving many agent
and subagent interactions over one stdio pipe. Stateless `respond` calls forced the caller to resend all
context every time, which the on-device model's small window makes expensive and lossy. Multi-turn work on
device, such as an iterative build-fix loop, needs conversation continuity.

## Decision

- `respond` accepts an optional `thread_id`. Omitted, daimon creates a thread with a generated id. Supplied and
  unknown, daimon creates a thread under that id. Supplied and known, the call continues that conversation.
- Every `respond` result carries `structuredContent` with `thread_id`, `created`, and `text`, so callers never
  parse the id out of prose.
- `instructions` and `tools` bind at creation. Passing them for an existing thread is a tool error rather than
  a silent ignore.
- `close_thread` frees a thread. Threads also evict least-recently-used beyond a capacity (32 by default) so a
  long-lived server cannot accumulate sessions without bound. Threads live only in memory, for the process's
  lifetime.
- Each thread is an actor wrapping one `Agent`. Calls on the same thread serialise, because a session cannot
  answer two prompts at once; different threads run concurrently.
- `Agent`'s async methods are `nonisolated(nonsending)` so they execute in the caller's isolation, matching
  the framework's own `LanguageModelSession.respond`. This is what lets an actor own a non-`Sendable` agent
  under strict concurrency without escape hatches.
- When a thread's context fills, older turns are dropped and the prompt retried (ADR 0008); the result
  carries `condensed: true`. Only if recovery itself fails does the caller get a tool error telling it to close
  the thread and start another.

## Consequences

- Callers own thread lifetime. A subagent that starts a thread should close it.
- Thread ids are validated to `[A-Za-z0-9._-]{1,64}` so they are safe in logs and file names later.
- Persistence across server restarts, and the macOS 27 `ContextOptions` for context management, are
  candidates for future ADRs.
