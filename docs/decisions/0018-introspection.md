# ADR 0018: daimon's own state is readable, read-only, through every face

Date: 2026-09-20. Status: accepted.

## Context

daimon keeps state the operator and a calling harness need to see: the effective configuration after
defaults, which model and tools a conversation has, which commands are approved and for how long, and
the audit log of what actually happened. The CLI had `logs`, `approvals`, `doctor`, and `models`, but the
model could not look at any of it (so it could not answer "what is your policy?" or "what did you just
run?"), and an MCP client had to spend a model turn or parse a log file to learn what a delegated thread
did.

## Decision

- One `Introspection` type renders four views: configuration, status, approvals, audit. It is built once
  per conversation from the session's home, config, and store, plus a status closure.
- The views are exposed three ways with the same content: the model's `inspect` tool (bounded to 4 KiB,
  audited as a tool call), the MCP resources `daimon://config`, `daimon://status`, `daimon://approvals`,
  `daimon://audit`, and the template `daimon://audit/{session}`, and the CLI (`daimon config`; `logs`
  now reads through the same code).
- Everything is read-only. There is no tool or resource that changes config, approvals, or logs; those
  stay with the operator (`config.json`, `daimon approvals`, the file system).
- Nothing is redacted, because everything shown is local state the operator already owns and the audit
  log already contains command output by design (ADR 0010). What leaves the machine is governed by the
  model choice (ADR 0013), not by this feature: an `inspect` result is tool output like any other, and a
  `private-cloud` session sends it to Apple as it sends everything else.
- The status resource adds what only the server knows: live thread ids and the count of standing
  approvals.

## Consequences

- A calling harness can reconstruct what a thread did from `daimon://audit/{thread_id}` today; the
  "receipts" backlog item becomes a summary in the result rather than the only way to know.
- A model asked to read the audit log leaves a `tool.call` in it; that is correct and documented.
- Adding a view means one renderer in `Introspection` and, if it belongs on the wire, one resource.
