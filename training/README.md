# Training sets

Labelled examples for the fast, specialised classifiers of
[ADR 0038](../docs/decisions/0038-fast-specialised-classifiers.md), one `label<TAB>text` per line, `#`
for comments. Each file's header states its labels and every judgement rule applied, so a reviewer can
check the labels against them. None of these is built into the binary; the shipped risk classifier is
still trained from `harness/Sources/WispCore/Resources/risk-examples.tsv`.

Each task has its own directory with three parts, kept apart by family: `train.tsv` to learn from,
`dev.tsv` to choose between options (algorithms, tokenisation, training sets), and `test.tsv`, frozen,
for the numbers a decision is reported on and never used to choose anything. `labels.md` holds the
label definitions and judgement rules. Lines are compared in a canonical form, with shell plumbing that does not
change what a command is removed (`2>&1`, `2>/dev/null`, a `VAR=$(…)` wrapper, `VAR=value` prefixes,
`git -C <dir>`, `-q`) and case kept, since it matters in flags. A family is that form with what varies
between near-identical lines replaced: URLs, hex ids (glued to a name too), numbers (glued to letters
too, but not a flag's digit), file names, and path components other than dotfiles. Quoted text is kept,
since in a command it is often the code that runs. Near matches join a family too: 80% of words shared,
or the same words for lines under three words. `wisp classifier split` deals whole
families into parts, each label in proportion, the same way every time for a given seed, and
`TrainingSetsTests` fails if any two parts of a task, or the shipped risk examples and the risk dev set,
share an example exactly, after normalising, by family, or by near match. No overlap is allowed.

| Task | train | dev | test | Labels |
| --- | --- | --- | --- | --- |
| `risk` | 986 | 123 | 996 (627 safe, 344 moderate, 25 dangerous) | safe, moderate, dangerous |
| `secrets` | 527 | 93 | to come | secret, personal, none |
| `failures` | 542 | 96 | 400 (169 none, 71 test-failure, 59 error, 51 warning, 50 crash) | error, test-failure, warning, crash, none |
| `log-severity` | 451 | 80 | 381 (275 info, 64 error, 41 warning, 1 fault) | fault, error, warning, info |

The risk dev set is the 123 commands the evals measure (`RiskEvalSet` reads it). It has been used to
choose, so its scores are not test scores.

The test sets are real data: commands a developer ran through Claude Code and wisp, output of real
builds and test runs, and a Mac's own logs. Each was labelled by an agent that had not seen the training
data, reviewed adversarially by another (`reviews/*-test.md`, and `reviews/checks.md` for the overlap
checks), corrected, and, for risk, had its 29 uncertain labels decided by a person. They were
neutralised for publication (names of the user, machines, networks, and projects replaced; paths,
session ids, time zones, and credentials removed) and checked with `wisp scan --personal` and a search
for every replaced value. The risk test set's original wording stays on the Mac it came from, in
`~/.wisp/classifiers/risk/held-out.tsv`, so `wisp classifier train --from-audit` there never learns it.

What they cannot yet measure: risk has 25 dangerous commands, so no dangerous command rated safe bounds
that rate only below about 12%; log severity has one fault. Both need more real cases.

## How they were made

On 2026-09-26 one agent drafted the four sets, the risk set starting from the bundled examples. A
second agent, which had not written them, reviewed each adversarially (`reviews/`): mislabels,
inconsistent rules, templated near-duplicates, leakage into the eval sets, shortcut tokens that predict
a label, unrealistic text, and data that could be real. Its 382 fixes were applied as proposed, and
then, by hand:

- **risk**: the fake host `x.example` marked 27 dangerous lines and 2 others, a shortcut the eval set
  shares; it was replaced by ten reserved documentation hosts and addresses (RFC 2606, RFC 5737), and
  16 moderate commands contacting the same hosts were added. No line equals an eval command.
- **secrets**: the drafts marked fake keys with `EXAMPLE`, a shortcut; the review replaced them with
  realistic invented values, so a U+200B sits after the fourth character of each value that looks
  like a credential, and inside private-key headers and AWS keys. Secret scanners then do not take the
  file for a leak; `RiskExamples.parse` strips U+200B, and any loader for these sets must too. A real
  address and a real person's name in the drafts were replaced.
- **log-severity**: aligned with `LogDigest`, which reads a level only from `log show`'s columns and
  guesses every other line's from keywords. `debug` became `info`, lines where a process died became
  `fault`, and about 40 lines gained written levels (`ERROR`, `[warn]`, `level=info`, glog's `E0926`),
  with some whose written level is wrong about the line. `fault` is small, 29 lines.

## Measured

The risk set against `RiskEvalSet`'s 123 held-out commands, the rules beside it, three training runs each
(`wisp classifier measure`):

| Trained on | Exact | Under | Dangerous rated safe |
| --- | --- | --- | --- |
| the bundled 292 | 97 to 101 | 0 | none |
| the draft, 955 | 101 to 104 | 2 to 3 | none |
| this set, 1,002 | 97 to 99 | 4 | none |

The draft scored higher partly through the `x.example` shortcut: two of this set's four under-ratings
are eval commands on that host that the draft caught by it. The other two (`kubectl delete deployment
… --all`, `gh repo edit --visibility public`) are real gaps, left as they are because they are held-out
cases. Before this set replaces the bundled examples, the eval set's own reliance on `x.example` needs
the same treatment, so the comparison is fair.
