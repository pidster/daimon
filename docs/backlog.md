# Backlog

Work agreed but not started, in rough priority order. Each item becomes an ADR when it is picked up.

## Policy

- Done 2026-09-19: each simple command in a line is checked and approved separately, remembered by
  program ([ADR 0015](decisions/0015-per-command-approval.md)).

## Enabling other harnesses (see the objective)

daimon's offer to another harness is work done locally that the harness would otherwise do with its own
tokens on a remote model: reading, condensing, classifying, extracting, and answering over local data, so
the caller's model never ingests the raw material. Other harnesses already run commands locally; that is
not the differentiator. Items, in order of leverage:

- **Receipts.** Every `respond` result reports what happened: tools called with arguments, files read,
  commands run with exit status, approvals asked and answered, tokens used. Makes delegated work
  verifiable by the caller.
- **Structured output.** `respond` accepts a JSON schema and returns validated JSON via guided
  generation, so results feed straight into the caller's logic.
- **Condensing tools.** Purpose-built MCP tools that keep raw content on the device and return small
  results: summarise a file or a diff (chunked map-reduce inside daimon), triage test or build output
  into a structured failure list, answer a question over a set of files, extract fields to a schema.
  These encode the prompting and paging so the caller does not have to coax a small model.
- **A measured task catalogue.** Extend the eval harness to those tools and publish success rates in
  `daimon://tools`, so a caller knows which delegations are reliable.
- **Reverse delegation through MCP sampling.** When the on-device model is stuck on a sub-step, ask the
  calling harness's model through the protocol, with data leaving the device only for that step and only
  with approval.
- **Roots and progress.** Use the client's declared roots as the sandbox's writable root; send progress
  notifications during long commands.

## Open design

- Approval for clients that do not render elicitation (mobile). Paused; see
  `docs/decisions/0014-persisted-approvals.md` for what exists.
