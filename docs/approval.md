# Risk classification and approval

Before `run_command` executes anything that passed the [policy](tools/run_command.md#policy-and-sandbox), a
classifier assesses the command's risk and, at or above a threshold, a human is asked. This is layer 3 of
[policy-and-sandboxing.md](policy-and-sandboxing.md) and is recorded in
[ADR 0011](decisions/0011-risk-classifier-and-approval.md).

## Levels

| Level | Meaning | Examples |
| --- | --- | --- |
| `safe` | Read-only, or reversible within the working directory | `ls`, `git status`, `grep` |
| `moderate` | Modifies files or state but is recoverable, or reaches the network | `touch`, `git commit`, `npm install`, `curl` |
| `dangerous` | Destructive, irreversible, privilege-escalating, or exfiltrates data | `rm -rf`, `git push --force`, `sudo`, `… \| sh` |

## Classifiers

Two run and the higher verdict wins (`CompositeRiskClassifier`):

- **Rules** (`RuleRiskClassifier`): regexes with a level and a reason each, covering privilege, deletion,
  history rewriting, credentials, uploads, network use, package installs, file modification, builds. Cheap,
  deterministic, tested against a labelled set. Rules cover the model's weak spot: ordinary modifications it
  tends to call safe.
- **Model** (`ModelRiskClassifier`): one fresh on-device session per command with a `@Generable` verdict.
  The verdict generates the one-sentence `reason` before the `risk` level, so the level follows the
  reasoning. The instructions give the model facts it otherwise guesses at (project build output is the
  project's own programs; filtering output is not network access; git reads are safe; anything that
  changes a file, setting, or repository state is at least moderate) and thirteen labelled examples.
  Sampling is greedy, so the same command always gets the same verdict. If the model is unavailable or
  fails it reports `moderate`, so a broken classifier asks rather than waves through.

Measured on this machine (`scripts/check eval`, 45 labelled commands, ten of them held out from the
instruction examples): the model alone scores 44 correct, 0 over, 1 under, identically on repeated runs,
at about 1.5 s per call. Its one miss (a shell redirect into a file, rated safe) is caught by the rules, so
the composite is right on all 45. Before the instruction rewrite the model scored 26 of 32 and varied
between runs. The eval suite asserts only the hard requirement (no dangerous command below moderate),
prints every miss with the model's reason, and is the place to add any command the model gets wrong.

## The gate

`ApprovalGate` (one per session) classifies, audits the verdict, and if the level is at or above the
threshold asks the session's `Approver`. Decisions: approve once, approve this exact command for the rest
of the session, or deny with a reason. A denial returns to the model as
`error: command not approved: …` so it can choose another approach.

| Entry point | Approver | Behaviour |
| --- | --- | --- |
| `daimon respond` | denying, unless `--yes` | Non-interactive: risky commands are refused with a message naming the three ways forward. `--yes` approves everything. |
| `daimon chat` | terminal | Prints the command, level, and reasons on stderr; reads `y`, `n`, or `a` (always this session). |
| `daimon mcp` | MCP elicitation, unless `--yes` | Asks the client's user through the protocol: Accept runs, Decline refuses, and a `scope` choice of once (default) or this session. If the client did not advertise elicitation, denies with a message telling the calling harness to run the command itself, start daimon with `--yes`, or lower the threshold. |

## Configuration

```json
{ "approval": { "threshold": "moderate", "useModel": true } }
```

| Field | Default | Meaning |
| --- | --- | --- |
| `threshold` | `moderate` | Ask at this level and above: `safe`, `moderate`, `dangerous`, or `never`. |
| `useModel` | `true` | Run the model classifier alongside the rules. `false` is faster and deterministic. |

`never` still classifies and audits; it just does not ask.

## Audit

Every command produces `classifier.verdict` (level, reasons, sources, seconds) and, when asked,
`approval.requested` and `approval.decided` (decision, reason; `cached` for session approvals). See
[logging.md](logging.md).

## Extending

Add a rule to `RuleRiskClassifier.defaultRules` with a reason a human would accept, and a case to the
labelled set in `ApprovalTests`. Add commands to `ClassifierEvalTests.labelled` when the model gets one
wrong, so the eval tracks it; keep held-out cases that do not resemble the instruction examples, or the
score measures recognition rather than judgement. Change the instructions only with a before-and-after
eval run in the commit message.
