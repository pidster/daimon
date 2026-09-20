# ADR 0021: `respond` returns a receipt derived from the audit log

Date: 2026-09-20. Status: accepted.

## Context

daimon's offer to another harness is work done locally that the harness can trust. Trust needs
verification: the caller wants to know which tools ran, which commands ran and how they exited, what
was refused, what was approved and at what scope, and whether anything failed, without spending a model
turn to ask or parsing the reply's prose. Since ADR 0018 a caller can read `daimon://audit/{thread_id}`,
but that is a second round trip, returns every field verbatim (a screenful per command), and needs the
caller to know the event catalogue. The backlog called this item receipts.

Two ways to build one: collect facts a second time at each site (the tool wrapper, the runner, the
gate), or derive them from the audit events those sites already write.

## Decision

A `Receipt` is a pure fold over one turn's audit events (`Receipt(events:turn:)`), built with no new
recording. Each `Conversation` tees its audit log into a `ReceiptCollector`, a bounded in-memory sink
(512 events) on the same turn clock; after a turn the MCP server takes that turn's events, which also
forgets them, and puts the fold in `structuredContent.receipt`. The receipt keeps identities, statuses,
counts, and timings and leaves outputs out: `tools` (name, arguments, result bytes and seconds, or the
error), `commands` (exit status, timed out, truncated, seconds), `denials` (policy or gate, with the
reason), `approvals` (decision, level asked at, scope given), `errors`, `condensed`, and `seconds`. Lists
are capped at 64 entries. No new audit kind is added; the receipt is not itself audited.

## Consequences

- The result and the log cannot disagree: a fact in the receipt is a fact in the log, and a caller who
  wants the verbatim command output follows `turn` into `daimon://audit/{thread_id}`.
- Adding a fact to a receipt means recording it in the audit log first, which is the order the
  definition of done already asks for. Token usage is absent for that reason: nothing records it yet.
- The collector costs a few hundred events of memory per open thread and one extra sink write per
  event. A turn's events are dropped when its receipt is taken, so a long thread does not grow it.
- The CLI faces have the collector too (every `Conversation` does) and do not use it yet; a `--receipt`
  flag would print the same fold.
- Tests: the fold is tested from constructed events (`ReceiptTests`), the tee and its bounds from a
  real `AuditLog`, and the shape on the wire from `DaimonServerWireTests` over a scripted model.
