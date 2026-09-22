# ADR 0029: The terminal chat is a Rust front end over a headless wisp

Date: 2026-09-22. Status: accepted. Amends the chat's place in `design.md`.

## Context

`wisp chat` lived inside the terminal's line discipline: replies, notes, and approvals in one
stream, a status line reprinted above every prompt, no editing beyond what cooked mode gives. The
reference tools (Claude Code, Codex) pin input and status at the bottom and let the conversation scroll
above, inline, keeping scrollback. Five ways to get there were compared (`proposals/2026-09-22-tui-spike.md`);
ratatui by process split was spiked on a branch and judged on a real terminal the same day.

## Decision

- `wisp chat --json` is the headless chat: the same `ChatLoop`, session, tools, gate, and audit, with
  its IO mapped onto JSON Lines (`ChatProtocol`, `LineRouter`, `JSONApprover`). Any front end can drive
  it; the plain `wisp chat` stays for terminals without the front end and for pipes.
- `tools/wisp-tui` is the terminal front end: a Rust program on ratatui's inline viewport, spawning
  `wisp chat --json`, committing finished lines to the terminal's own scrollback and drawing a band at
  the bottom with the reply in progress, an approval dialog, the input, and the status. wisp becomes a
  two-language product on purpose: Rust for what owns the terminal, Swift for everything the model,
  the policy, and the audit touch.
- One palette for both faces (`palette.rs`, `Style.Palette`): a pale blue in four tones for what wisp
  says, amber for attention, ember for danger, white for the conversation. Chosen by eye on
  2026-09-22 after a greener, darker first set was rejected.
- Padding is cells: a one-cell text inset everywhere, the input's tint edge to edge with half-block
  strips above and below, since a terminal cannot tint less than a row.

## Consequences

- The protocol is a contract to keep and version; its shape is documented in `wisp.md` and may still
  change (a `turn` event, pre-rendered versus raw events) before it is called stable.
- Two binaries to build, test, and ship: the gate already runs both; the formula does not yet install
  the front end, and `wisp chat` does not yet hand off to it. Those, with line editing and history in
  the input, are the next work (`backlog.md`).
- Tests: the loop over the protocol without a model (`ChatProtocolTests`), the band rendered to
  ratatui's test backend, key handling, and event rendering; the viewport itself needs a real terminal.
