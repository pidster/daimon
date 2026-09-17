# ADR 0003: Stream via a delta callback, not an AsyncSequence wrapper

Date: 2026-09-17. Status: accepted.

## Context

The first draft exposed streaming as `AsyncThrowingStream<String, Error>` built by spawning a `Task` that
iterated `session.streamResponse(to:)`. Under Swift 6 strict concurrency the compiler rejected it: the closure
captured the non-`Sendable` `LanguageModelSession`, risking a data race.

## Decision

`Agent.stream(_:onDelta:)` is an `async throws` method that iterates the framework's stream on the caller's
task and invokes a synchronous callback per delta. It returns the final text.

## Consequences

- No `@unchecked Sendable` or `nonisolated(unsafe)` anywhere, keeping the strict-concurrency guarantee intact.
- Callers that want an `AsyncSequence` can build one on their own actor; the library does not force a
  concurrency model on them.
- The framework's snapshots are cumulative, so `Agent` computes deltas by prefix comparison.
