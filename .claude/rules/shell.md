---
paths:
  - "scripts/**"
  - ".githooks/**"
---

# Shell guidance for scripts and hooks

- POSIX `sh` (`#!/bin/sh`, `set -eu`); no bashisms, since the hook runs under whatever `sh` is.
- `scripts/check` is the single implementation of every check. The hook and CI call it; add a check by
  adding a function and a `case` arm, and document it in `docs/engineering.md`.
- Checks that need the on-device model or are slow (`eval`, `coverage`) are separate subcommands and never
  part of `all`.
- Hygiene checks run over `git diff --cached` only. New hygiene rules must be cheap and must not produce
  false failures on refactors; prefer a printed reminder to a block when in doubt (see the docs reminder).
- Quote every variable; use `printf '%s\n'` rather than `echo` for data.
