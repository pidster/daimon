# Managing the context window

The on-device model's window is small. `LanguageModelError.contextSizeExceeded` reports both the limit and
the offending count; on this machine a session died at 4,096 tokens. This page records what the framework
offers, what daimon does, and what it deliberately does not do yet.

## What the framework offers (macOS 27 SDK)

| API | Use |
| --- | --- |
| `Transcript` is `Codable` and a `RangeReplaceableCollection` of `Entry` | Save, inspect, trim, and rebuild conversations. Entries are `.instructions`, `.prompt`, `.toolCalls`, `.toolOutput`, `.response`. |
| `LanguageModelSession(model:tools:transcript:)` | Start a session from any transcript, which is how a condensed conversation continues. |
| `SystemLanguageModel.tokenCount(for:)` | Counts tokens for a prompt, instructions, tools, schema, or transcript entries, so budgets can be measured rather than guessed. Costs a model call. |
| `LanguageModelError.contextSizeExceeded(ContextSizeExceeded)` | Carries `contextSize` and `tokenCount`. |
| `ContextOptions` | Despite the name, sets `reasoningLevel` (`light`, `moderate`, `deep`) and schema inclusion. Not window management. |

There is no automatic summarisation or sliding window in the framework. Whatever fits must be arranged by
the caller.

## What daimon does

`Agent` has a `ContextPolicy`:

- `.failFast`: the error propagates.
- `.condense(keepTurns:)` (default, four turns): on overflow, the session is rebuilt from the transcript as
  it was before the failing prompt, condensed with `Transcript.condensed(keepTurns:)`, and the prompt is
  retried once. If it fails again, the error propagates.

`condensed(keepTurns:)` keeps the leading `.instructions` entry and the last N turns, where a turn is a
`.prompt` plus everything up to the next prompt, so tool calls and outputs stay with the prompt that caused
them. It is pure and tested. `Agent.condensations` counts recoveries so callers can tell the user; `chat`
prints a note and MCP `respond` sets `structuredContent.condensed`.

`Agent.contextTokens()` exposes the framework's count for the current transcript; `chat` shows it with
`/tokens`.

Tools are the other half of the answer. `run_command` keeps only the tail of output and `read_file` pages a
file, so a single tool result cannot fill the window.

## Design rules

1. Never let one tool result exceed a fixed byte budget (4 KiB by default). Paging beats truncation where the
   model can ask for more.
2. Keep tool descriptions short: every registered tool's schema is in the prompt on every turn.
3. Treat overflow as expected, not exceptional; recover, tell the caller, continue.
4. Prefer dropping whole turns to editing entries, so the transcript stays a faithful record.

## Not done yet, and why

- **Summarisation instead of dropping.** Asking the model to summarise the dropped turns into a new
  instructions entry preserves more, at the cost of a model call and a transcript that no longer records what
  was said. Worth an experiment once there is a workload that suffers from plain dropping.
- **Proactive trimming.** Calling `tokenCount(for:)` before each prompt and condensing when near the limit
  avoids the failed call, but doubles model calls. The reactive path is cheap and sufficient so far.
- **Map-reduce for long documents.** Summarising a file longer than the window needs chunked sub-sessions
  and a merge step. That belongs in a dedicated tool (a Rust candidate), not in `Agent`.
