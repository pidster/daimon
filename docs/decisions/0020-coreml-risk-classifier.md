# ADR 0020: A Core ML text classifier can judge commands, behind a versioned contract, never alone

Date: 2026-09-20. Status: accepted. Extends [ADR 0011](0011-risk-classifier-and-approval.md).

## Context

The approval gate judges each command with the rule set plus Apple's on-device model (ADR 0011). The
model classifier is accurate on the labelled set but costs about 1.5 s per command and depends on Apple
Intelligence being enabled. An operator may want a classifier that is theirs: trained on their own
commands, fast, deterministic, and chosen independently of which model runs the conversation.

## Decision

- `approval.classifier` chooses: `rules`, `system-model` (the default, unchanged), or `coreml`. The old
  `useModel: false` still means `rules`. The choice is independent of `model`.
- `CoreMLRiskClassifier` runs a Core ML text classifier beside the rules in the same composite, so the
  rules, the threshold, and the human stay authoritative and the higher level wins.
- **Contract, version 1.** The model takes one string input `text` (the command line, trimmed, runs of
  whitespace collapsed to one space, case kept) and gives one string output `label` whose values are
  `safe`, `moderate`, `dangerous`. Its creator metadata carries `wisp.classifier.contract = "1"` and
  `wisp.classifier.labels = "safe,moderate,dangerous"`. A model that declares another contract, other
  labels, or other features is rejected at load. The version string in the model's metadata is its
  identity in the audit.
- **Failure is `moderate`.** No configured path, a missing asset, a model Core ML cannot load, a contract
  mismatch, an inference error, no prediction, an unknown label, or a top-label probability below
  `approval.coremlMinimumConfidence` (default 0.6) all produce a `moderate` verdict with the reason, and
  the reason is recorded. Nothing the classifier does can lower a level or grant an approval.
- **Confidence** is recorded only from the model's own label probabilities, when it gives them (Create
  ML text classifiers do). It is the model's estimate, not calibrated; the minimum-confidence threshold
  is a guard against guessing, not a measurement of accuracy.
- **Audit.** `classifier.verdict` gains `metadata`: `coreml.model`, `coreml.version`, `coreml.label`,
  `coreml.confidence`, and `coreml.fallback` when the verdict is a fallback, against the same turn and
  command as every other verdict.
- `scripts/train-risk-classifier` trains a model from a `text,label` CSV with Create ML and writes the
  contract metadata; `docs/examples/risk-labels.csv` is the eval set; `scripts/check eval` measures a
  model named by `WISP_COREML_MODEL` with the same hard requirement as the on-device model: no
  dangerous command rated safe.

## Consequences

- Loading and predicting are cheap (milliseconds); a source `.mlmodel` is compiled once per process.
- The eval set is 45 commands. A model trained on it proves the pipeline, not its judgement. Measured
  on 2026-09-20: trained on all 45 it scores 45/45 on the same rows; trained on the 35 non-held-out
  rows it got 5 of the 10 held-out right, and two dangerous commands it called `safe` (`find … -delete`,
  `security find-generic-password`) reached `moderate` only through the confidence guard. That is why
  the guard exists and why the rules run beside it. Before an operator relies on a model, they evaluate
  it on commands like theirs; loading and producing valid labels is not evidence of suitability.
- General intent classification and model routing are outside this decision.

## Amendment, 2026-09-25

[ADR 0038](0038-fast-specialised-classifiers.md) adds contract version 2 (version 1's features and
labels, with shell punctuation split into tokens), which `wisp classifier train` writes; version 1
models still load. The classifier now loads its model once, not per verdict. `scripts/train-risk-classifier`
and `docs/examples/risk-labels.csv` are removed: they trained on the eval set. The two dangerous
commands this ADR's measurement saw called `safe` are revisited there: `find … -delete` is now caught by
the rules, and a classifier trained on the bundled examples rates neither below `moderate`.

