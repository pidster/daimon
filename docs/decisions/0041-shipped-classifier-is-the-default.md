# 0041: The fast classifier each release ships is the default

Date: 2026-09-26. Status: accepted. Reverses ADR 0038's "system-model stays the default risk
classifier" (amendment "measured on the three-way split").

## Context

Since ADR 0020, `approval.classifier` defaulted to `system-model`: Apple's on-device language model
judged every command the rules did not settle, beside the rules. ADR 0038 kept that default until a
trained classifier could be trusted on real commands.

On 2026-09-26 the shipped default classifier, `risk@X.Y.Z-default`, was retrained on 2,135 examples,
1,075 of them real commands. On the frozen 996 real test commands, beside the rules, the two compare:

| Classifier | Exact | Over | Under | Dangerous rated safe | Per verdict |
| --- | --- | --- | --- | --- | --- |
| shipped default (`coreml`) | 817 | 129 | 50 | 4 | under 1 ms |
| on-device model (`system-model`) | 664 | 261 | 71 | 1 | 2.5 s at P50, 12 s at P95 |

The on-device model's run was measured under heavy load from other builds on the same Mac, when some
verdicts took over 40 s. The Core ML classifier answered in 0.24 ms at P50 under the same load, because
it is a small model run on the CPU inside wisp's process. The language model runs in a system service
and slows with everything else the Mac is doing. The gate waits on the classifier before every command
the rules and the read-only list do not settle.

Of the shipped default's four dangerous commands rated safe, one (a credential read with `printenv`)
is now caught by a rule. The other three can't be judged from the command's text: a script piped in
on stdin, and two calls of a project hook that deletes worktrees. The on-device model's one miss,
`scripts/release`, is of the same kind.

## Decision

`approval.classifier` defaults to `coreml`. With no `approval.coremlModel`, that is the version this
build ships, installed into `~/.wisp/classifiers/risk` on first use. `system-model` and `rules` stay
available by setting them. The pre-0.2 `approval.useModel` keeps its meaning: `true` is
`system-model`, `false` is `rules`. `wisp doctor` checks the classifier, and names the shipped version
when none is configured.

The rules stay the floor. The classifier can only raise a level, a fallback is `moderate`, and the
human decides everything at or above the threshold (ADR 0038).

## Consequences

- The gate judges a command in about a millisecond instead of about two seconds, and its speed no
  longer depends on how busy the Mac is.
- Prompts on safe commands fall by half on the test set (129 over-ratings against 261), and exact
  ratings rise from 664 to 817.
- Dangerous commands rated safe are 4 in 25 on the test set, against 1. The test set has too few
  dangerous commands to measure that rate closely, so a dangerous-only test slice is the next piece
  of work. Commands whose danger is not in their text stay the human's to catch.
- Anyone who set `approval.classifier` keeps their choice. Only the unset default changes.
