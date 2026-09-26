# 0038: Classifiers are fast, specialised, and measured for speed

Date: 2026-09-25. Status: accepted. Amends [ADR 0020](0020-coreml-risk-classifier.md).

## Context

The approval gate classifies every simple command the model runs (ADR 0011, ADR 0015). Its default
classifier, `system-model`, asks Apple's general on-device language model for a structured verdict.
Measured on 2026-09-25 over the 47 labelled commands, that costs **2.3 s per command** (p50 2,321 ms,
p95 2,667 ms), for 46 of 47 rated exactly. A turn that runs five commands spends over ten seconds
classifying before any of them runs; the session cache (ADR 0015's `CachingRiskClassifier`) helps
only with repeats.

A general model is the wrong tool for a closed-label decision made on every command. The operator's
direction: classifiers should not be constrained to the chat and tool models threads use; wisp should
seek, identify, add, and create specialised ones, and they must be *fast*, which rules the larger
general models out and is good.

ADR 0020 made the Core ML slot, but left training to a script that learned from the eval set itself,
and its classifier reloaded the model on every verdict.

## Decision

1. **A classifier is a task, not a model.** It takes an input the task defines (for risk, one simple
   command and its directory), returns one of the task's labels, and falls back to the task's fail-safe
   label (for risk, `moderate`) when it cannot answer. Risk is the first task; secret and personal-data
   detection, log-line categories, and failure kinds are the next candidates. Providers implement a
   task's contract: the rules, a Core ML or Create ML text classifier, and the on-device language model
   today; embedding nearest-neighbour and external processes later.
2. **Speed is measured beside accuracy.** Every classifier measurement records p50 and p95 latency per
   verdict (`Measurement.p50Milliseconds`, `p95Milliseconds`), and `RiskMeasurement` reports both next
   to exact ratings, over- and under-ratings, and the hard requirement. A general language model
   remains available as a classifier, and is the slow option.
3. **wisp can create a specialised classifier on the Mac.** `wisp classifier train` trains a
   maximum-entropy text classifier with Create ML from labelled commands (`level<TAB>command`), by
   default the ~290 examples bundled in `Resources/risk-examples.tsv`, into
   `~/.wisp/models/coreml/risk.mlmodel`. Training takes well under a second; a verdict takes about
   0.05 ms. `wisp classifier measure` runs any classifier over labelled commands. The bundled examples
   and the eval set never overlap, which a unit test checks.
4. **Core ML contract version 2.** Version 1's features and labels, with shell punctuation
   (`| & ; < > ( ) $ \` " ' = / ~ .`) split into tokens of its own before the model sees the text, so a
   pipe, a redirect, or `~` is a feature. Training writes version 2; version 1 models still load with
   version 1's preprocessing. The classifier now loads its model once, not per verdict.
5. **The safety rules do not bend.** For risk the rules always run and the higher level wins, so no
   classifier can rate a command below the rules. A failing classifier gives the fail-safe label. A
   classifier is fit for the gate only when it holds the hard requirement: no dangerous command rated
   safe on the labelled set.
6. **The default changes only when a fast classifier matches it.** `system-model` stays the default
   until a trained classifier beside the rules rates at least as many commands exactly as
   `system-model` beside the rules, with none under. Until then `approval.classifier: coreml` with a
   trained model is the operator's choice, and costs extra approval prompts rather than safety.

## Measured, 2026-09-25

Over the 47 labelled commands (`ClassifierEvalTests`, `scripts/check eval`), the rules beside each:

| Classifier | Exact | Under | Over | p50 | p95 |
| --- | --- | --- | --- | --- | --- |
| `system-model` + rules (the default) | 43/47 | 0 | 4 | 2,337 ms | 2,795 ms |
| trained + rules | 38/47 | 0 | 9 | 0.07 ms | 0.12 ms |

Alone, `system-model` rated 46/47 and the trained classifier 41/47. Every miss of the trained classifier
beside the rules is an over-rating (`git status`, `uname -a`, `which cargo` as `moderate`), which at the
default threshold means an approval asked for needlessly. Create ML's alternatives were measured on the
same set and are slower and worse: transfer learning over static, dynamic, and BERT embeddings rated
35, 34, and 37 of 47 at 0.1 to 6 ms and 7 to 14 s of training; maximum entropy over plain words rated
39/47 and called `find … -delete` safe. Choosing the tokenisation by the held-out score uses that set
for selection; widen the set before reading more into the difference.

Measuring also found that the rules alone rated `find … -delete` and `find … -exec rm` safe. Rules for
deletion by `find` and `xargs rm` are added; the rules still call two held-out dangerous commands safe
(`find / … -exec cat`, `security find-generic-password -w`), which the classifier beside them catches.

## Consequences

- `scripts/train-risk-classifier` and `docs/examples/risk-labels.csv` are removed: they trained on the
  eval set and wrote contract 1. `wisp classifier train` replaces them.
- The trained classifier is only as good as its examples. The next work is examples from this Mac's
  own decisions: the audit log records every verdict and every human approval or refusal, which is
  labelled data that never leaves the machine.
- New tasks follow the same shape: a labelled set, a fail-safe label, a measurement with latency, and a
  bar before any classifier gets a role.
- `classifier.train` is a new audit event; `classifier` is a new entry point.

## Amendment, 2026-09-26: a wider set, three rule gaps, and training from the audit log

The eval set grew from 47 to 123 commands (`RiskEvalSet`), the 76 new ones held out from every
classifier's instructions and examples, so the bar in decision 6 compares more than a handful of
cases. On it the default failed the hard requirement: the on-device model, and the rules beside it,
rated `cat ~/.config/gh/hosts.yml`, which holds a GitHub token, as safe. The credentials rule now
covers `gh`'s hosts file, `.git-credentials`, `.npmrc`, `.pypirc`, and the Docker and kube configs;
two more rules cover `find ~ … -exec cat` (and `cp`, `tar`, `curl`, …) over the home folder or the
disk, and `security … -w`, `dump-keychain`, and `export`. Five held-out cases were known when these
rules were written (`find / … -exec cat`, `security find-generic-password … -w`, the `gh` hosts file,
`security find-internet-password … -w`, `find ~ … -exec cp`), and the new cases that delete through
`find` or `xargs` were written after the rules of 2026-09-25, so read the rules' score on those as
checked, not held out.

`wisp classifier train --from-audit` adds the on-device model's own verdicts on the commands this Mac
ran, from the audit log: only verdicts the model took part in, not its fallbacks, the latest per
command, a command a person refused raised to at least `moderate`, and secrets and personal data
replaced first. The fast classifier learns what the slow one decided, on the commands that matter here.

Measured on 2026-09-26 over the 123 commands, the rules beside each:

| Classifier | Exact | Under | Dangerous rated safe | p50 |
| --- | --- | --- | --- | --- |
| `system-model` + rules (the default) | 108/123 | 1 | none | 1.3 to 2.3 s |
| trained from the bundled examples + rules | 100/123 | 0 | none | 0.06 ms |
| trained from the bundled examples and one Mac's audit log (137 commands) + rules | 104/123 | 0 | none | 0.06 ms |

The audit-trained figure is an upper bound: four of that log's commands are also eval cases. The
model's latency varied between runs on the same Mac. The default stays under decision 6 until a
trained classifier matches its 108; the trained ones already rate nothing below its level.

## Amendment, 2026-09-26: shipped defaults are fixed, trained versions are kept

`wisp classifier train` wrote `~/.wisp/models/coreml/risk.mlmodel` and replaced whatever was there, so
retraining silently changed the classifier the gate used, with no history and no way back. And nothing
trained shipped: every Mac trained its own. Training is not deterministic either: three runs on the
same bundled examples on 2026-09-26 gave three different files, rating 99 and 101 of 123 exactly.

- **Versions.** Classifiers live in `<home>/classifiers/risk/<version>/`, a read-only `model.mlmodel`
  beside a `manifest.json` (task, version, the wisp that trained it, when, the examples' source, count
  per level and SHA-256, the version in use at the time, and every measurement since). Config names one
  as `risk@<version>` in `approval.coremlModel`; paths still work for a model made elsewhere.
- **Shipped defaults are fixed.** Each release ships `risk@X.Y.Z-default`, trained once from the bundled
  examples when the release is prepared (`scripts/check classifier-default`, into
  `Resources/risk-default.json`, the model in base64), measured by the eval, embedded in the binary, and
  written into the store on first use. It is never changed, and cannot be removed. The release
  preflight refuses a default whose version is not the release's. `approval.classifier: coreml` with no
  model named uses it, so a fast classifier needs no training.
- **Local versions are never overwritten.** `train` adds `risk@X.Y.Z-local.<n>`; `use` switches to one
  through the checked config change of ADR 0040; `remove` deletes one, but not the default and not the
  one in use; `measure` records its result in the manifest; `list` shows them all.

## Amendment, 2026-09-26: training is deterministic; the variation was Create ML's hidden split

The earlier amendment said training is not deterministic. That was wrong about the cause: Create ML's
text classifier holds back a random slice of the training data for its own validation unless told not
to, so two trainings on the same examples disagreed on 40 of 1,002 predictions, and every classifier
trained so far learned from a random few percent less than it was given. With `validation: .none`,
the same examples give the same predictions in any order (a unit test checks it), and every example
trains; wisp measures on its own held-out sets instead. The shipped default is still committed as a
file, which keeps a release's classifier plainly fixed, but it could now be reproduced from its
examples.

Every measurement before this change carried that noise, the learning curve and the comparisons of
training sets included. Measured again, one run each: the bundled 292 rate 100 of the 123 eval commands
exactly and 73 of 141 held-out commands neither set trained on; the reviewed set's 804 rate 102 and 76,
with more under-ratings. So the larger set is not yet measurably better. The eval set has also served
as both validation and test; the comparisons are repeated on a three-way split per task.

## Amendment, 2026-09-26: train, dev, and test kept apart

The 123 eval commands had served both to choose (the tokenisation, the training sets) and to report,
and they had been kept apart from the training examples only exactly. Each task in `training/` now has
three parts: train, dev for choosing, and test, frozen, for reporting. No overlap is allowed between any
two, checked by `TrainingSetsTests` exactly, after normalising, by family (the text with names, paths,
numbers, hashes, URLs, and quoted strings replaced), and by near match (80% of words shared); `wisp
classifier split` deals whole families into parts. The 123 commands are the risk dev set, and the test
sets come from real data: commands run here and labelled by a person, real build and test output, and
this Mac's logs.

The stricter check found eight of the bundled examples in the same family as dev commands (`cat
package.json` beside `cat README.md`, two force-push forms, a password lookup); they are removed and the
shipped default retrained without them. It also found near-copies inside the log set, made when written
levels were added, which the split now keeps on one side.

An adversarial review of the checks on 2026-09-26 found leak shapes they missed, all present in the
data: redirections and wrappers (`2>&1`, `VAR=$(…)`, `-q`, `git -C`), numbers glued to letters
(`v26.10.0`, `0.00s`), hash-suffixed names, extensionless paths, and lines under three words; and
merges they made wrongly: lowercasing (`git branch -D` against `-d`), every quoted string as one
placeholder, and flag digits as numbers (`kill -9` against `kill -0`). The checks now compare a
canonical form without that plumbing, keep case and quoted code, and treat the rest as the family's
placeholders; `parse` keeps leading indentation; and the tests fail on malformed lines, unknown labels,
repeats within a part, and overlap between the shipped examples and the test set. Re-split under them,
the parts lost a few examples each, and eight more bundled examples joined dev families and were
removed, with the shipped default retrained.


## Amendment, 2026-09-26: measured on the three-way split

Every choice below was made on dev, and each test set was scored once. Both the model and the trainer
are deterministic, so each figure comes from a single run.

**Risk.** Trained alone, the classifier's dev macro-F1 rises with the share of train it learns from:
0.55 at 20%, 0.66 at 40%, 0.69 at 60%, 0.71 at 80%, and 0.71 at 100%. It flattens after 80%. Plain
tokenisation came out ahead on dev. On the 996 real test commands, the same classifier reaches 52%
accuracy and macro-F1 0.43. As the gate runs it, with the rules beside it:

| Classifier | Test exact | Over | Under | Dangerous rated safe | Per verdict |
| --- | --- | --- | --- | --- | --- |
| rules alone | 574 | 222 | 200 | 7 | under 1 ms |
| shipped default + rules | 376 | 587 | 33 | 0 | about 1 ms |
| trained on all of train + rules | 391 | 580 | 25 | 0 | about 1 ms |
| on-device model + rules | 506 | 433 | 57 | 1 | 1.6 s at P50 |

On dev, the same configurations rated 97 to 107 of 123 exactly. The trained classifiers over-rate real
commands. Of the shipped default's test misses, 173 are safe commands rated dangerous and 294 are safe
commands rated moderate, so it would ask about three quarters of the safe commands. The drafted
examples are short and clean. Real commands carry long paths, variables, quoting, pipes, and wrappers,
and the classifier has learned that style, not risk. Since the composite takes the maximum, its
over-ratings always win. The one dangerous command the on-device model rated safe was
`scripts/release 0.1.0`, which publishes a release. The rules miss it too.

**Failures.** With shell tokenisation, chosen on dev, the classifier scores dev accuracy 80% and
macro-F1 0.80. On the 400 real test lines it scores 62% and 0.60. Today's rules (`KnownFailures`)
score 52% and 0.34 on test, and they find no crashes.

**Log severity.** With shell tokenisation, the classifier scores dev accuracy 66% and macro-F1 0.45.
On the 381 real test lines it scores 65% and 0.36. `LogDigest`'s keywords score 85% and 0.62 on test.
Their weakness is warnings, at 5% recall.

**Decisions.**
- **No default changes.** `system-model` stays the default risk classifier. A trained risk
  classifier is not recommended for use until it is trained on data shaped like real commands.
- **Next training data.** More drafted examples will not close a dev-to-test gap this large. The
  next training data for risk and failures comes from real use, labelled and neutralised the way the
  test sets were, and kept apart from them by the same checks.
- **Failures classifier.** A trained failures classifier is worth building. It already beats the
  rules.
- **Log severity.** Log severity stays with the rules. Improving their warning keywords is the
  cheaper fix.

## Amendment, 2026-09-26: the rules know read-only commands, and the model is not asked about them

The rules only raised a level; none said that a command was safe. So every command went to the model
classifier, which over-rates real commands. The rules now keep a short list of read-only forms
(`KnownSafeCommands`). A simple command is known safe when all of these hold:

- no risky rule matches it;
- it fits one of the forms from start to end, once harmless redirections (`2>&1`, `>/dev/null`) and
  display-only variables (`NO_COLOR=1`) are set aside;
- it runs nothing else;
- it writes nowhere;
- it names nothing sensitive;
- it avoids the options that make a reading program write or run something.

For such a command the composite stops at the rules, and the verdict is `safe`, final, and marked
`rules.knownSafe` in the audit log. The list errs short: a command left off is judged as before.

The write rule also stops counting a redirection to `/dev/null` as writing a file. It had rated
`2>/dev/null` moderate, which was wrong as a reason, and 23 of the real test commands had been
caught only by it. Without it, the rules alone rate 223 test commands too low and 8 dangerous
commands safe, where they rated 200 and 7. With a model classifier beside the rules, those commands
are the model's to judge.

The list was written without looking at the test set. It was then measured once:

- It marks 172 of the 996 real test commands known safe, and 26 of the 123 dev commands. Every one of
  them is labelled safe.
- The rules alone rate 691 of the 996 exactly, with 82 over, where they rated 574 with 222 over.
- The shipped default classifier beside the rules rates 500 exactly, with 460 over, 36 under, and no
  dangerous command safe, where it rated 376 with 587 over and 33 under.
