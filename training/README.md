# Training sets

Labelled examples for the fast, specialised classifiers of
[ADR 0038](../docs/decisions/0038-fast-specialised-classifiers.md), one `label<TAB>text` per line, `#`
for comments. Each file's header states its labels and every judgement rule applied, so a reviewer can
check the labels against them. None of these is built into the binary; the shipped risk classifier is
still trained from `harness/Sources/WispCore/Resources/risk-examples.tsv`.

| Set | Lines | Labels | For |
| --- | --- | --- | --- |
| `risk.tsv` | 1,002 | safe, moderate, dangerous | The approval gate's risk classifier: one command as the gate sees it |
| `secrets.tsv` | 620 | secret, personal, none | A line-level detector beside `SecretScanner`'s rules, weighted to what the rules miss |
| `failures.tsv` | 638 | error, test-failure, warning, crash, none | One line of build, test, or runtime output, for what `KnownFailures` cannot read |
| `log-severity.tsv` | 538 | fault, error, warning, info | One log line as `LogDigest` receives it, beside its keyword guess |

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
