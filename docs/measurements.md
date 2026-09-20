# Measurements: what the model can be trusted with

Every delegated task daimon offers is measured against a small eval set on a real model, and the
result ships with the tool catalogue so a calling harness knows which delegations are reliable before it
spends a call ([ADR 0026](decisions/0026-task-catalogue.md)). A measurement is one eval run on one
Mac on one day; it is evidence, not a certification.

## Where to see them

- `daimon tools --markdown` and the MCP resource `daimon://tools.md`: a `Measured:` line under each
  tool that has one, with the task, `passed/total`, the model, the date, and what a pass was.
- `daimon tools --json` and `daimon://tools`: the same as `measurements` on each tool.
- `daimon://measurements`: every measurement, including tasks that are not one model tool (`triage`,
  the risk classifier, schema-shaped replies).

## What is measured

| Task | Eval | A pass is |
| --- | --- | --- |
| `classifier.system-model` | `ClassifierEvalTests`, 45 labelled commands, ten held out | the command rated at exactly its level; separately, no dangerous command below moderate is a hard requirement |
| `triage` | `TriageEvalTests`, abridged swift build, swift test, cargo test, and pytest output | an expected failure found, by test name or file:line |
| `edit_file.replace` | `ToolEvalTests`, five small files | after read_file then edit_file replace, the file is exactly as intended |
| `respond.schema` | `ToolEvalTests`, six code snippets | the schema-shaped reply parses and names the language |

The sets are small on purpose: they prove the pipeline and catch regressions. Widen a set when the
model gets a case wrong in practice, keeping cases that do not resemble the prompt's own examples.

## How to run and record

```
scripts/check eval
```

runs `ModelEvalTests` on the configured model with `DAIMON_EVAL_RECORD` pointing at
`harness/Sources/DaimonCore/Resources/measurements.json`; each test merges its `Measurement` into
that file, replacing the previous one for the same task and model. The file is embedded at build time
by the `EmbedSystemPrompt` plugin, so the numbers a binary reports are the numbers committed with it.
Commit the file with the change that moved the numbers, and say so in the message. The release
preflight runs the eval, so a release never ships with stale numbers.

The eval asserts only floors (half or three quarters recall, and the classifier's hard requirement);
everything else is reported and recorded. Run `DAIMON_MODEL_TESTS=1 swift test --filter ToolEvalTests`
in `harness/` for one suite.

## Reading a measurement

```json
{ "task": "triage", "model": "system", "date": "2026-09-20", "passed": 7, "total": 7,
  "notes": "expected failures found across abridged swift build, swift test, cargo test, and pytest output, by test name or file:line" }
```

`tool` names the model tool the task exercises when it is one, so the catalogue can attach it. A task
with no measurement for the configured model has not been measured there; that is not the same as
failing.
