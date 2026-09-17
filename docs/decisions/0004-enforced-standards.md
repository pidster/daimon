# ADR 0004: Standards are enforced by tooling, shared between hook and CI

Date: 2026-09-17. Status: accepted.

## Context

The project owner requires the highest standard of engineering practice. Standards that live only in prose
decay; standards that are checked twice (once in a hook, once in CI) drift apart.

## Decision

One script, `scripts/check`, implements every check. The pre-commit hook in `.githooks/` and the CI workflow
both call it. `swift-format` (bundled with Xcode as `swift format`) is the formatter and linter; no third-party
lint dependency. The build runs with `-warnings-as-errors`.

The hook also runs the low-cost hygiene checks that caught real problems on day one: conflict markers,
trailing whitespace, large files, and the commit author email being a GitHub noreply address (the first push
was rejected for using a private address).

## Consequences

- The hook needs a warm build cache to be fast; a cold run compiles dependencies once.
- Developers must run `scripts/check install-hooks` after cloning; git does not version hooks.
- Adding a check means editing one script, and CI picks it up automatically once it is re-enabled (it is
  manual-only until a macOS 27 runner is provisioned).
