---
paths:
  - "docs/**"
  - "README.md"
  - "CLAUDE.md"
---

# Documentation guidance

- `docs/README.md` is the index; add a row for every new page. Pages describe the current state and are
  edited in place. Decision records are append-only: a superseded ADR keeps its file and gains a
  "Superseded by" or "Amends" line, and the newer ADR names what it changes.
- ADR format: title, `Date: … Status: accepted.`, then `## Context`, `## Decision`, `## Consequences`.
  Number sequentially; record measurements that informed the decision, not just the conclusion.
- Which page a change touches: a tool → `docs/tools/<name>.md` and the table in `docs/tools/README.md`;
  a CLI flag, subcommand, config field, or environment variable → `docs/daimon.md`; an MCP tool or
  behaviour → `docs/mcp.md`; an audit event kind → `docs/logging.md`; a component or data flow →
  `docs/design.md`; a non-obvious or hard-to-reverse choice → a new ADR.
- Write for the reader named in the page: user pages give contracts, limits, and examples; design pages
  give mechanisms and rationale. Tables for parallel facts, prose for argument. Keep code out of prose;
  commands and JSON go in fenced blocks.
- Verified facts only. If a claim was measured or probed, say so and where (`scripts/check eval`, a probe
  on this machine on a date). Do not document intended behaviour as if it existed.
- The README is the front door: intro, quick start, doc map, developer setup. Detail belongs in `docs/`.
