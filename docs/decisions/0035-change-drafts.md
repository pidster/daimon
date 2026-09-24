# ADR 0035: Change drafts are written from the diff summary, with the shape enforced in code

Date: 2026-09-24. Status: accepted. Builds on [ADR 0023](0023-condensing-tools.md).

## Context

Commit messages, pull request descriptions, and changelog lines are chores a remote model is often
asked to do from a diff it must first read in full. `summarise_diff` already reduces a diff to a
headline, a line per file, and review flags, on the device. What remained was the writing, and the
conventions a reviewer expects: a subject under 72 characters in the imperative, no trailing period, a
wrapped body.

## Decision

- **`ChangeDraft` writes from `DiffSummary`'s report, never from the raw diff**: one fresh schema-shaped
  turn (`subject`, `points`) over the per-file lines and the flags, so the prompt stays
  small whatever the diff's size. Files are listed code first, then tests, then docs and the changelog,
  because a diff's path order puts `CHANGELOG.md` and `docs/` ahead of the code they describe, and the
  first draft of a real commit (2026-09-24) led with its documentation. The summary's headline is left
  out for the same reason: it comes from the diff's first chunk. A subject cut at 72 characters also
  drops a trailing connective ("and", "with", "to"), which the same draft ended on.
- **The shape is applied in code**: one line, a leading capital, no trailing period, at most 72
  characters cut at a word; a body wrapped at 72. The model is not trusted with arithmetic on length.
- **The commit body ends with `Why: <the reason for this change, which the diff cannot say>`.** A diff
  shows what changed, not why; a reason the model made up would read as fact in the history.
- **Faces**: the MCP tool `draft_change` (`kind`: `commit`, `pr`, `changelog`; the diff from a command,
  default `git diff --cached`, or a file) on a conversation `draft-<id>`, and `wisp draft [kind]`, which
  reads a piped diff or runs `git diff --cached` under the policy, sandbox, and approval. An empty diff is
  refused with a sentence rather than drafted.

## Consequences

- Measured with `DraftEvalTests` on 2026-09-24 on the system model: commit subjects for five small
  diffs (a retry loop, a changed default, a new flag, an off-by-one fix, a docs addition), twice each,
  named what the change is about 10 and 9 of 10 times on two runs ("Fix pagination range bounds"). An
  earlier prompt's example subject, "Add retry to the upload client", matched the retry fixture and was
  copied word for word; it was replaced with an unrelated one before these runs. The eval measures the
  subject's content; the shape is guaranteed by the code.
- Small changes draft well on the system model; large ones do not. For this ADR's own commit (22 files,
  718 lines added) the system model wrote "Set up git commit prompt for draft changes" with an invented
  point ("Removed outdated subcommands"), in 2.5 minutes; `ollama:qwen3.8:27b` wrote "Add draft command to
  generate commit, PR, or changelog text from a diff" with accurate points. The docs say to use a larger
  local model for large changes.
- A large diff costs the summary's turns (about 2 s per 4 KiB on the system model) plus one.
- The draft is a draft: the tool's description and `wisp draft --help` say to review it.
- Tests without the model: the subject and wrapping rules, file ordering, each kind's shape, the
  fallback to the headline on a malformed answer, the empty-diff refusal, the whole flow over scripted
  judges, and the MCP tool over the wire.
