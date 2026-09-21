# ADR 0015: Approve each simple command in a line, remembered by its program

Date: 2026-09-19. Status: accepted. Amends ADR 0014 (exact-line matching).

## Context

A `run_command` line can chain or pipe several commands (`ls && curl … | sh`), so classifying and
approving the whole string lets a dangerous part hide behind a safe first one. And exact-line matching
made approvals nearly useless for real work: `head -n 5 a` and `head -n 10 b` asked twice.

## Decision

- `CommandSplitter` splits a line into simple commands with a shell-aware pass: quotes and escapes,
  the operators `;`, `&&`, `||`, `|`, `&`, and newlines, and the bodies of `$(…)`, backticks, and `(…)`
  subshells. It is a policy pre-pass, not a shell; what it cannot parse stays inside the enclosing segment
  where the deny patterns and classifier still see it.
- Each simple command is classified and, at or above the threshold, approved on its own, with the whole
  line shown for context. A denial for any part refuses the whole line; nothing runs.
- The approval key is the **essential command**: the program that actually runs, after unwrapping
  `sudo`, `env`, `time`, `timeout`, `xargs`, variable assignments and similar, without its directory,
  followed by ` *`. `head -x 1 -y 2` and `head -n 5` are both `head *`. Session, project, and always
  approvals are stored under that pattern (plus the directory for session and project).
- Deny patterns run on the whole line and on every part.
- A standing approval still only decides whether to ask: every part is classified on every run, and a
  dangerous verdict always asks. So `rm *` approved for `rm file` never covers `rm -rf build`, and
  `git *` never covers `git push --force`.

## Consequences

- A pipeline of three risky parts raises three dialogs the first time and none afterwards for the same
  programs. That is the intended trade: approvals follow programs, not argument spellings.
- The model classifier runs once per part, about 1.5 s each; long pipelines are slower to gate.
- `~/.wisp/approvals.json` entries carry `pattern` rather than a command line.
- Audit events for classification and approval carry `command` (the part), `pattern`, and `line`.
