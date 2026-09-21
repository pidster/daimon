# ADR 0027: Approval patterns include the verb for multiplexer programs

Date: 2026-09-21. Status: accepted. Amends [ADR 0015](0015-per-command-approval.md).

## Context

ADR 0015 keys approvals on the program that runs: `git *`, `head *`. For a program like `git` the
program is not the imperative; the verb is. On 2026-09-20 a session answer to `git commit` was served
from the key `git *` for `git push` and `git add` too, which the receipts made visible. The operator's
reading was the opposite, that the approval was too specific, because the dialog shows the whole
command line. Both readings point at the same fact: the key did not name the acting part.

## Decision

- Programs whose first word is the verb are listed in `Resources/multiplexers.txt`, one per line,
  embedded at build time by the same plugin as the system prompt, so the list is a plain file in the
  tree and the binary needs nothing beside it. Fixed for now; not a `config.json` setting.
- For those programs the splitter finds the verb: the first word after the program that is not an
  option, an option's value (`-C dir`), or a toolchain selector (`+nightly`), and that looks like a
  word. The pattern becomes `git commit *`; a program with no verb stays `git *`. Everything else is
  unchanged: `ls *`, `head *`.
- A standing approval stored under the pre-verb pattern (`git *`) is still honoured for any verb of that
  program until it expires, so an existing approvals file keeps working and nothing is migrated.
- Classification is unchanged: every part is still judged on its full text every time, and a dangerous
  verdict still always asks, so `git push *` never covers `git push --force`.

## Consequences

- One session answer covers the verb, not the program: commits stop asking, pushes ask once on their
  own. Roughly one more dialog per verb per session.
- The list is a judgement; adding a program changes what an approval covers, which is why it lives in
  the tree beside the system prompt rather than in a user's config.
- Tests without the model: verb extraction for the shapes above (`CommandSplitterTests`), verbs
  remembered apart and the legacy pattern honoured through a real store (`ApprovalTests`).
