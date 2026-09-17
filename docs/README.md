# daimon documentation

| Document | Purpose |
| --- | --- |
| [objective.md](objective.md) | What daimon is for and what "done" looks like |
| [design.md](design.md) | Architecture: components, data flow, extension points |
| [fm-cli.md](fm-cli.md) | What the Apple `fm` command family does and does not offer, as observed |
| [context-management.md](context-management.md) | The small context window: framework APIs, what daimon does, design rules |
| [policy-and-sandboxing.md](policy-and-sandboxing.md) | Investigation of tool policy and sandboxing options (decision pending) |
| [engineering.md](engineering.md) | Standards, tooling, the pre-commit gate, and CI |
| [decisions/](decisions/) | Architecture Decision Records, one per significant decision |

Conventions: documents describe the current state and are edited in place. Decisions are append-only; a
superseded ADR keeps its file and gets a `Superseded by` line. Add an ADR whenever a choice would be
non-obvious to a newcomer or expensive to reverse.
