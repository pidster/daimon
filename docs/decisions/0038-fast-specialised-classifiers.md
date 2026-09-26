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

